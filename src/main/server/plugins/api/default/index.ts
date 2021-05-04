import * as WS from "@trufflesuite/uws-js-unofficial";
import * as path from "path";
import * as fs from "fs";
import * as QueryString from "querystring";

import { IPluginConfig, IPluginConfigPropItemType, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { ApiPluginBase } from "../base";
import { HttpRouterV1 } from "./router/http";
import { Response } from "./response";
import { DEFAULT_PASSWORD } from "./constants";
import { ApiDatabase } from "./database";
import { AuthApi } from "./common/auth";
import { Token } from "./database/entity";
import { Parsers } from "./helpers/parsers";
import { ClientWsRequest, UpgradedSocket, WsRoute } from "./types";
import type { HttpRouterBase } from "./router/http/base";

/**
 * The configuration for this BlueBubbles plugin
 */
const configuration: IPluginConfig = {
    name: "default",
    type: IPluginTypes.API,
    displayName: "Default Transport",
    description: "The default transport for BlueBubbles",
    version: 1,
    properties: [
        {
            name: "password",
            label: "Password",
            type: IPluginConfigPropItemType.PASSWORD,
            description: "Enter a password to use for authenticating clients.",
            default: DEFAULT_PASSWORD,
            placeholder: "Enter a password...",
            required: true
        },
        {
            name: "port",
            label: "Socket Port",
            type: IPluginConfigPropItemType.NUMBER,
            description: "Enter the local port to open up to outside access.",
            default: 1234,
            placeholder: "Enter a number between 100 and 65,535.",
            required: true
        }
    ],
    dependencies: [] // ['messages_api.default'] // Other plugins this depends on (<type>.<name>)
};

export default class DefaultApiPlugin extends ApiPluginBase {
    // The instance of the uWS.js app
    app: WS.TemplatedApp = null;

    // A list of connected sockets
    sockets: UpgradedSocket[] = [];

    // An instance of a plugin-specific database
    db: ApiDatabase;

    routers: HttpRouterBase[] = [];

    // Currently supported API versions
    apiVersions = [1];

    /**
     * A map specifying which routes go to which static files
     *
     * @returns The static files map
     */
    // eslint-disable-next-line class-methods-use-this
    get staticMap(): { [key: string]: any } {
        return {
            "/": path.join(__dirname, "index.html"),
            "/dist/css/*": null,
            "/dist/js/*": null,
            "/dist/img/*": null,
            "favicon.ico": path.join(__dirname, "favicon.ico")
        };
    }

    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    /**
     * Lifecycle method called before starting up the plugin.
     * This will initialize the DB and the uWS.js app
     */
    async pluginWillLoad() {
        // Setup the database
        this.db = new ApiDatabase(this);
        await this.db.initialize();

        // Setup server
        this.app = WS.App();
    }

    /**
     * Lifecycle method to startup the actual plugin services. For
     * this startup method, we are calling methods to serve static files,
     * serve the HTTP routes, as well as websockets
     */
    async startup() {
        // Serve static routes
        for (const uri of Object.keys(this.staticMap)) {
            this.serveStatic(uri, this.staticMap[uri]);
        }

        // Setup middlewares and routes
        this.setupWebsockets();
        this.setupHttpRoutes();

        // Start listening
        const port = this.getProperty("port") as number;
        if (port && port > 0 && port < 65535) {
            this.app.listen(port, _ => {
                this.logger.info(`Listening on port, ${port}`);
            });
        } else {
            this.logger.error(`Invalid port provided! Port provided: ${port}`);
        }
    }

    /**
     * Handler/Helper for serving static files
     *
     * @param urlPath The URL path to match
     * @param filePath The corresponding static file path (or null for wildcards)
     */
    serveStatic(urlPath: string, filePath: string = null) {
        if (!this.app) return;

        this.app.get(urlPath, (res: WS.HttpResponse, req: WS.HttpRequest) => {
            try {
                res.end(fs.readFileSync(`${__dirname}${filePath ?? req.getUrl()}`));
            } catch (e) {
                console.error(e);
                Response.error(res, 500, e.message);
            }
        });
    }

    /**
     * Sets up the websocket handlers for uWS.js
     */
    async setupWebsockets() {
        if (!this.app) return;

        this.logger.info("Setting up websocket...");

        this.app.ws("/ws/*", {
            upgrade: async (res: WS.HttpResponse, req: WS.HttpRequest, context: WS.WebSocketBehavior) => {
                console.log(`A WebSocket connected via URL: ${req.getUrl()}!`);

                let json: { [key: string]: any } = null;
                let params: { [key: string]: any } = null;

                try {
                    json = Parsers.readJson(res);
                } catch (ex) {
                    // Don't do anything
                }

                try {
                    params = QueryString.parse(req.getQuery());
                } catch (ex) {
                    // Don't do anything
                }

                /**
                 * Upgrades the connection, and injects some context
                 *
                 * @param auth The token data to inject
                 */
                const next = (auth: Token): void => {
                    res.upgrade(
                        {
                            auth,
                            pluginDb: this.db,
                            plugin: this,
                            json,
                            params
                        },
                        req.getHeader("sec-websocket-key"),
                        req.getHeader("sec-websocket-protocol"),
                        req.getHeader("sec-websocket-extensions"),
                        context
                    );
                };

                // Check for the token
                const authorization = req.getHeader("authorization");
                if (!authorization || authorization.trim().length === 0) return next(null);

                // If the token is present, get it from the DB and make sure it's not expired
                const token = await AuthApi.getToken(this.db, authorization);
                if (!token || token.isExpired()) return next(null);

                // Pass the token on to the next handler
                return next(token);
            },
            open: (ws: WS.WebSocket) => {
                // Re-brand to incorporate new injected fields
                const sock = ws as UpgradedSocket;

                // Register routes
                sock.subscribe(WsRoute.NEW_MESSAGE);

                // Store the socket instance
                this.sockets.push(sock);
            },
            message: (ws: WS.WebSocket, message: ArrayBuffer, isBinary = false) => {
                const decoder = new TextDecoder("utf-8");
                const msg = JSON.parse(decoder.decode(message)) as ClientWsRequest;

                switch (msg.path) {
                    default: {
                        this.logger.warn(`Websocket route, "${msg.path}" does not exist`);
                    }
                }
            }
        });

        this.logger.info("Finished setting up websocket...");
    }

    setupHttpRoutes() {
        this.logger.info("Setting up routes...");

        // Load all the routers for the APIs
        if (this.apiVersions.includes(1)) {
            this.routers.push(new HttpRouterV1(this));
        }

        // Serve all the routers
        for (const i of this.routers) {
            this.logger.info(`  -> Serving routes for router: ${i.name}`);
            i.serve();
        }

        this.logger.info("Finished setting up routes...");
    }

    async shutdown() {
        for (const socket of this.sockets) {
            socket.close();
        }

        WS.us_listen_socket_close(this.app);
        this.app = null;
    }
}
