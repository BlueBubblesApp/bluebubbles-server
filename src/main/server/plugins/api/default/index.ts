import * as WS from "@trufflesuite/uws-js-unofficial";
import * as path from "path";
import * as fs from "fs";
import * as QueryString from "querystring";

import { FileSystem } from "@server/fileSystem";
import { IPluginConfig, IPluginConfigPropItemType, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { ApiPluginBase } from "../base";
import { onAbort, HttpRoute } from "./routes/http";
import { Response } from "./response";
import { DEFAULT_PASSWORD } from "./constants";
import { ApiDatabase } from "./database";
import { SharedAuth } from "./shared/sharedAuth";
import { Token } from "./database/entity";
import { Parsers } from "./helpers/parsers";
import { ClientWsRequest, UpgradedHttp, UpgradedSocket, WsRoute } from "./types";
import { getPlugins } from "./routes/http/v1/plugin";
import { tokenAuth } from "./routes/http/v1/auth";
import { ping } from "./routes/http/v1/general";
import { InjectMiddleware } from "./middleware/http/injectMiddleware";
import { AuthMiddleware } from "./middleware/http/authMiddleware";

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
    app: WS.TemplatedApp = null;

    sockets: UpgradedSocket[] = [];

    db: ApiDatabase;

    get certDir() {
        return path.join(this.path, "ssl");
    }

    get certPath() {
        return path.join(this.certDir, "cert.pem");
    }

    get keyPath() {
        return path.join(this.certDir, "key.pem");
    }

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

    async pluginWillLoad() {
        // Setup the database
        console.log("INITING DB");
        this.db = new ApiDatabase(this);
        await this.db.initialize();

        // Setup server
        this.app = WS.App();
    }

    async startup() {
        // Serve static routes
        for (const uri of Object.keys(this.staticMap)) {
            this.serveStatic(uri, this.staticMap[uri]);
        }

        // Setup middlewares and routes
        this.setupWebsockets();
        this.setupRoutesV1();

        const port = this.getProperty("port") as number;
        if (port && port > 0 && port < 65535) {
            this.app.listen(port, listenSocket => {
                this.logger.info(`Listening on port, ${port}`);
            });
        } else {
            this.logger.error(`Invalid port provided! Port provided: ${port}`);
        }
    }

    serveStatic(urlPath: string, filePath: string = null) {
        if (!this.app) return;

        this.app.get(urlPath, (res, req) => {
            try {
                res.end(fs.readFileSync(`${__dirname}${filePath ?? req.getUrl()}`));
            } catch (e) {
                res.writeStatus("500 Internal Server Error");
                res.end("500 - Internal Server Error");
            }
        });
    }

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
                const token = await SharedAuth.getToken(this.db, authorization);
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

    public protected(
        ...handlers: ((res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void>)[]
    ): (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void> {
        const injector = InjectMiddleware.middleware({
            plugin: this,
            pluginDb: this.db,
            hasEnded: false
        });

        return HttpRoute.base(injector, AuthMiddleware.middleware, ...handlers);
    }

    public unprotected(
        ...handlers: ((res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void>)[]
    ): (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void> {
        const injector = InjectMiddleware.middleware({
            plugin: this,
            pluginDb: this.db,
            hasEnded: false
        });

        return HttpRoute.base(injector, ...handlers);
    }

    async setupRoutesV1() {
        this.logger.info("Setting up routes...");

        // General routes
        this.app.get(HttpRoute.v1("/ping"), this.unprotected(ping));

        // Plugin routes
        this.app.get(HttpRoute.v1("/plugin"), this.protected(getPlugins));

        // Authentication routes
        this.app.post(HttpRoute.v1("/token"), this.unprotected(tokenAuth));

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
