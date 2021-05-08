import * as WS from "@trufflesuite/uws-js-unofficial";
import * as path from "path";
import * as fs from "fs";

import { IPluginConfig, IPluginConfigPropItemType, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { MessagesApiPluginBase } from "@server/plugins/messages_api/base";
import { ApiEvent } from "@server/plugins/messages_api/types";
import { DataTransformerPluginBase } from "@server/plugins/data_transformer/base";
import { messageToSpec } from "@server/plugins/messages_api/default/helpers/responseTransformers";
import type { Message } from "@server/plugins/messages_api/default/entity/Message";

import { ApiPluginBase } from "../base";
import { HttpRouterV1 } from "./router/http";
import { Response } from "./helpers/response";
import { DEFAULT_PASSWORD } from "./constants";
import { ApiDatabase } from "./database";
import { AuthApi } from "./common/auth";
import { Token } from "./database/entity";
import { Parsers } from "./helpers/parsers";
import { ClientWsRequest, UpgradedSocket, WsMessage, WsRoute } from "./types";
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
    dependencies: ["messages_api.default"] // Other plugins this depends on (<type>.<name>)
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
        for (const uri in this.staticMap) {
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

        this.startMessagesApiListeners();
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
                this.logger.info(`A WebSocket connected via URL: "${req.getUrl()}"`);

                // Parse the request for headers, params, and JSON data
                const parsed = await Parsers.parseRequest(req, res);

                /**
                 * Upgrades the connection, and injects some context
                 *
                 * @param auth The token data to inject
                 */
                const next = (auth: Token): void => {
                    // If we don't have an auth token, kill the socket connection
                    if (!auth) {
                        res.close();
                        return;
                    }

                    let injectedMeta = { auth, plugin: this };
                    injectedMeta = { ...injectedMeta, ...parsed };

                    res.upgrade(
                        injectedMeta,
                        req.getHeader("sec-websocket-key"),
                        req.getHeader("sec-websocket-protocol"),
                        req.getHeader("sec-websocket-extensions"),
                        context
                    );
                };

                // Check for the token & in the correct format
                const authorization = req.getHeader("authorization");
                if (!authorization || authorization.trim().length === 0 || !authorization.startsWith("Bearer "))
                    return next(null);

                // If the token is present, get it from the DB and make sure it's not expired
                const tokenValue = authorization.split("Bearer ")[1];
                const token = await AuthApi.getToken(this.db, tokenValue);
                if (!token || token.isExpired()) return next(null);

                // Pass the token on to the next handler
                return next(token);
            },
            close: (_: WS.WebSocket, __: number, ___: ArrayBuffer) => {
                this.logger.info(`A WebSocket disconnected`);
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
                const utfMessage = decoder.decode(message);
                this.logger.debug(`Websocket message received: "${utfMessage}"`);

                const msg = JSON.parse(utfMessage) as ClientWsRequest;
                if (!msg?.path) return;

                // Let's rebrand the websocket with the injected info (this will get passed to the router)
                const websocket = ws as UpgradedSocket;

                // Handle the message paths
                switch (msg.path) {
                    default: {
                        this.logger.warn(`Websocket route, "${msg.path}" does not exist`);
                    }
                }
            }
        });

        this.logger.info("Finished setting up websocket...");
    }

    /**
     * Sets up the HTTP routes, for all supported versions of the API
     */
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

    private emitToSockets(data: WsMessage) {
        const { event } = data;
        this.logger.info(`Forwarding Messages API event, "${event}" to socket clients...`);
        this.app.publish(WsRoute.NEW_MESSAGE, JSON.stringify(data));
    }

    async startMessagesApiListeners(): Promise<void> {
        // Fetch the Messages API plugin
        const apiPlugins = (await this.getPluginsByType(IPluginTypes.MESSAGES_API)) as MessagesApiPluginBase[];
        const apiPlugin = apiPlugins && apiPlugins.length > 0 ? apiPlugins[0] : null;

        // If we don't have a messages API, log an error, we need one to listen for API Events
        if (!apiPlugin) {
            this.logger.error("No Messages API plugin found! Message updates will not be supported!");
            return;
        }

        // Get the currently set transformer plugin
        const transformerPlugins = (await this.getPluginsByType(
            IPluginTypes.DATA_TRANSFORMER
        )) as DataTransformerPluginBase[];
        const transformerPlugin = transformerPlugins && transformerPlugins.length > 0 ? transformerPlugins[0] : null;

        // Message events
        apiPlugin.on(ApiEvent.NEW_MESSAGE, data => {
            this.emitToSockets({ event: ApiEvent.NEW_MESSAGE, data: transformMessage(transformerPlugin, data) });
        });
        apiPlugin.on(ApiEvent.UPDATED_MESSAGE, data => {
            this.emitToSockets({ event: ApiEvent.UPDATED_MESSAGE, data: transformMessage(transformerPlugin, data) });
        });
        apiPlugin.on(ApiEvent.MESSAGE_MATCH, data => {
            this.emitToSockets({ event: ApiEvent.MESSAGE_MATCH, data: transformMessage(transformerPlugin, data) });
        });

        // Re-brand group name changes as new message events (makes it easier for the clients)
        apiPlugin.on(ApiEvent.GROUP_NAME_CHANGE, data => {
            this.emitToSockets({ event: ApiEvent.NEW_MESSAGE, data: transformMessage(transformerPlugin, data) });
        });
        apiPlugin.on(ApiEvent.GROUP_PARTICIPANT_ADDED, data => {
            this.emitToSockets({ event: ApiEvent.NEW_MESSAGE, data: transformMessage(transformerPlugin, data) });
        });
        apiPlugin.on(ApiEvent.GROUP_PARTICIPANT_REMOVED, data => {
            this.emitToSockets({ event: ApiEvent.NEW_MESSAGE, data: transformMessage(transformerPlugin, data) });
        });
        apiPlugin.on(ApiEvent.GROUP_PARTICIPANT_LEFT, data => {
            this.emitToSockets({ event: ApiEvent.NEW_MESSAGE, data: transformMessage(transformerPlugin, data) });
        });

        // Error handling
        apiPlugin.on(ApiEvent.MESSAGE_SEND_ERROR, data => {
            this.emitToSockets({ event: ApiEvent.MESSAGE_SEND_ERROR, data: transformMessage(transformerPlugin, data) });
        });
        apiPlugin.on(ApiEvent.MESSAGE_TIMEOUT, data => {
            this.emitToSockets({ event: ApiEvent.MESSAGE_TIMEOUT, data: transformMessage(transformerPlugin, data) });
        });
    }

    /**
     * Shuts down the uWS.js app by closing all sockets and then,
     * "deleting" the app object
     */
    async shutdown() {
        for (const socket of this.sockets) {
            socket.close();
        }

        WS.us_listen_socket_close(this.app);
        this.app = null;
    }
}

const transformMessage = (transformer: DataTransformerPluginBase, data: Message) => {
    const specData = messageToSpec(data);
    if (transformer && transformer.messageSpecToApi) {
        // transform
        return transformer.messageSpecToApi(specData);
    }

    return specData;
};
