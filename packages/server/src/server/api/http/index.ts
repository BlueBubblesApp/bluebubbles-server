/* eslint-disable max-len */
import { Server as SocketServer, ServerOptions } from "socket.io";

// HTTP libraries
import KoaApp from "koa";
import koaJson from "koa-json";
import KoaRouter from "koa-router";
import koaCors from "koa-cors";
import * as https from "https";
import * as http from "http";
import * as fs from "fs";

// Internal libraries
import { Server } from "@server";
import { isNotEmpty, onlyAlphaNumeric } from "@server/helpers/utils";
import { EventCache } from "@server/eventCache";
import { CertificateService } from "@server/services/certificateService";

import { HttpRoutes as HttpRoutesV1 } from "./api/v1/httpRoutes";
import { SocketRoutes as SocketRoutesV1 } from "./api/v1/socketRoutes";
import { ErrorMiddleware } from "./api/v1/middleware/errorMiddleware";
import { createServerErrorResponse } from "./api/v1/responses";
import { checkServerPassword, getSocketPassword } from "./passwordAuth";
import { HELLO_WORLD } from "@server/events";
import { ScheduledService } from "../../lib/ScheduledService";
import { Loggable } from "../../lib/logging/Loggable";
import { ProxyServices } from "@server/databases/server/constants";
import { ProcessSpawner } from "@server/lib/ProcessSpawner";
import { AuthThrottle, resolveClientAddress } from "./authThrottle";

/**
 * This service class handles all routing for incoming socket
 * connections and requests.
 */
export class HttpService extends Loggable {
    tag = "HttpService";

    koaApp: KoaApp;

    httpServer: https.Server | http.Server;

    socketServer: SocketServer;

    socketOpts: Partial<ServerOptions> = {
        pingTimeout: 1000 * 60 * 2, // 2 Minute ping timeout
        pingInterval: 1000 * 60, // 1 minute ping interval
        upgradeTimeout: 1000 * 30, // 30 Seconds

        // 100 MB. 1000 == 1kb. 1000 * 1000 == 1mb
        maxHttpBufferSize: 1000 * 1000 * 100,
        allowEIO3: true,
        transports: ["websocket", "polling"],

        // Reject a new session before engine.io accepts any of its payloads (up to maxHttpBufferSize
        // each), so an unauthenticated client can't make the server buffer data. engine.io only calls
        // this for a session's first request, and passes the same query that becomes socket.handshake.query.
        allowRequest: (req, callback) => {
            let query = (req as any)._query as Record<string, unknown>;
            if (!query) {
                query = Object.fromEntries(new URL(req.url ?? "", "http://localhost").searchParams.entries());
            }

            // Refuse blocked clients before looking at the password, so a blocked
            // client learns nothing about its guesses
            const clientAddress = resolveClientAddress(req.socket.remoteAddress, req.headers["x-forwarded-for"]);
            if (this.authThrottle.retryAt(clientAddress) > 0) {
                this.log.debug(`Rejecting client connection from blocked address ${clientAddress}.`);
                callback("Too many failed authentication attempts", false);
                return;
            }

            const pass = getSocketPassword(query);
            const result = checkServerPassword(pass);
            const authorized = result === "ok";
            if (!authorized) {
                this.log.info(`Rejecting client connection (IP: ${clientAddress}). Authentication failed.`);
                if (result === "invalid") this.recordAuthFailure(clientAddress, String(pass).trim());
            }

            callback(authorized ? null : "Authentication failed", authorized);
        }
    };

    httpOpts: any;

    sendCache: EventCache;

    clearCacheService: ScheduledService;

    portCheckerService: ScheduledService;

    authThrottle: AuthThrottle;

    initialize() {
        this.httpOpts = {};

        // Re-created on every (re)initialize, so restarting the server clears all blocks
        this.authThrottle = new AuthThrottle();

        // Configure certificates
        try {
            const use_custom_cert = Server().repo.getConfig("use_custom_certificate") as boolean;
            const proxy_service = Server().repo.getConfig("proxy_service") as string;
            if (onlyAlphaNumeric(proxy_service).toLowerCase() === onlyAlphaNumeric(ProxyServices.DynamicDNS)) {
                if (use_custom_cert) {
                    // Only setup certs if the proxy service is
                    this.log.info("Starting Certificate service...");
                    CertificateService.start();

                    // Add the SSL/TLS PEMs to the opts
                    this.httpOpts.cert = fs.readFileSync(CertificateService.certPath);
                    this.httpOpts.key = fs.readFileSync(CertificateService.keyPath);
                }
            }
        } catch (ex: any) {
            this.log.error(`Failed to start Certificate service! ${ex.message}`);
        }

        // Create the HTTP server
        this.koaApp = new KoaApp();
        this.configureKoa();

        if (this.httpOpts.cert && this.httpOpts.key) {
            this.log.info("Starting up HTTPS Server...");
            this.httpServer = https.createServer(this.httpOpts, this.koaApp.callback());
        } else {
            this.log.info("Starting up HTTP Server...");
            this.httpServer = http.createServer(this.koaApp.callback());
        }

        // Create the socket server and link the http context
        this.socketServer = new SocketServer(this.httpServer, this.socketOpts);
        this.sendCache = new EventCache();

        // Every 6 hours, clear the send cache
        this.clearCacheService = new ScheduledService(() => {
            this.sendCache.purge();
        }, 1000 * 60 * 60 * 6);
    }

    configureKoa() {
        if (!this.koaApp) return;

        // Allow cross origin requests
        this.koaApp.use(koaCors());

        // This allows us to properly pull the IP from the request
        this.koaApp.proxy = true;

        // Catch any errors that escape the route-level middleware
        this.koaApp.use(ErrorMiddleware);

        // Request bodies are parsed per-route, after authentication (see BodyMiddleware)

        // Don't show it "pretty" by default, but only if there is a `pretty` param
        this.koaApp.use(
            koaJson({
                pretty: false,
                param: "pretty"
            })
        );

        // Configure the routing
        const router = new KoaRouter();
        HttpRoutesV1.createRoutes(router);

        // Use the router
        this.koaApp.use(router.routes()).use(router.allowedMethods());
    }

    /**
     * Records a wrong password and raises a warning (which lands in the
     * notification drawer) naming the address when it gets that client blocked.
     */
    recordAuthFailure(address: string | null, credential: string) {
        const { blockAlert, globalAlert } = this.authThrottle.recordFailure(address, credential);
        if (blockAlert) {
            const until = new Date(blockAlert.retryAt).toLocaleString();
            Server().log(
                `Blocked client ${blockAlert.address} after ${blockAlert.failures} different incorrect passwords ` +
                    `in the last ${blockAlert.rule.label}. Authentication from this address is refused until ${until}. ` +
                    `If this is one of your own devices, restart the server to clear the block.`,
                "warn"
            );
        }

        if (globalAlert) {
            Server().log(
                `${globalAlert.failures} different incorrect passwords have been tried against the server in the ` +
                    `last ${this.authThrottle.globalRuleLabel}. Someone may be trying to guess your password; ` +
                    `consider changing it to a long, random one.`,
                "warn"
            );
        }
    }

    /**
     * Checks to see if another process is listening on the socket port.
     */
    async checkIfPortInUse(port: number) {
        try {
            // Check if there are any listening services
            // lsof exits non-zero (and we land in the catch) when nothing is listening
            const output = await ProcessSpawner.executeCommand('lsof', [
                '-nP',
                `-iTCP:${Number(port)}`,
                '-sTCP:LISTEN'
            ], {}, "PortChecker");
            if (output.includes(`:${port} (LISTEN)`)) return true;
        } catch {
            // Don't show an error, I believe this throws a "false error".
            // For instance, if the proxy service doesn't start, and the command returns
            // nothing, it thinks it's an actual error, which it isn't
        }

        return false;
    }

    /**
     * Creates the initial connection handler for Socket.IO
     */
    async start() {
        if (!this.socketServer) return;

        const port = Server().repo.getConfig("socket_port") as number;
        const portInUse = await this.checkIfPortInUse(port);
        if (portInUse) {
            throw new Error(`Unable to start HTTP service! Port ${port} is already in use!`);
        }

        /**
         * Handle all other data requests
         */
        this.socketServer.on("connection", async socket => {
            socket.on("disconnect", (_: any) => {
                this.log.info(`Client disconnected (Total Clients: ${this.socketServer.sockets.sockets.size})`);
            });

            // Basic authentication. allowRequest already rejected bad passwords at the handshake;
            // this re-check covers a password change since then. An unset server password never
            // authenticates anyone, and a rejected client must never get any event handlers registered.
            if (checkServerPassword(getSocketPassword(socket.handshake.query)) !== "ok") {
                this.log.info(`Closing client connection. Authentication failed.`);
                socket.disconnect(true);
                return;
            }

            this.authThrottle.recordSuccess(
                resolveClientAddress(socket.handshake.address, socket.handshake.headers["x-forwarded-for"])
            );

            this.log.info(
                `Client Authenticated Successfully (Total Clients: ${this.socketServer.sockets.sockets.size})`
            );

            /**
             * Error handling for all Socket.IO event handlers.
             * If there are any errors in a socket event, they will be handled here.
             *
             * Socket.IO middleware (`socket.use`) runs before the handler and can't see
             * errors thrown by async handlers, so each handler is wrapped instead. A console
             * message will be printed, and the error is sent to the client's ack callback
             * (or emitted as an "exception" when there isn't one), so a bad request is always
             * answered rather than becoming an unhandled rejection.
             */
            const registerHandler = socket.on.bind(socket);
            socket.on = ((event: string, listener: (...args: any[]) => any) =>
                registerHandler(event, async (...args: any[]) => {
                    try {
                        await listener(...args);
                    } catch (ex: any) {
                        const message = ex?.message ?? String(ex);
                        this.log.error(`Socket server error in "${event}"! ${message}`);

                        const res = createServerErrorResponse(message);
                        const ack = args[args.length - 1];
                        if (typeof ack === "function") ack(res);
                        else socket.emit("exception", res);
                    }
                })) as any;

            // Pass to method to handle the socket events
            SocketRoutesV1.createRoutes(socket);
        });

        // Start the server
        this.httpServer.listen(port, () => {
            this.log.info(`Successfully started HTTP${isNotEmpty(this.httpOpts) ? "S" : ""} server`);

            // Once we start, let's send a hello-world to all the clients
            Server().emitMessage(HELLO_WORLD, null);
        });
    }

    private async closeSocket(): Promise<void> {
        return new Promise((resolve, reject): void => {
            if (this.socketServer) {
                this.socketServer.removeAllListeners();
                this.socketServer.close((err: Error) => {
                    this.socketServer = null;
                    if (err) {
                        reject(err);
                    } else {
                        resolve(null);
                    }
                });
            } else {
                resolve(null);
            }
        });
    }

    private async closeHttp(): Promise<void> {
        return new Promise((resolve, reject): void => {
            if (this.httpServer) {
                this.httpServer.close((err: Error) => {
                    if (err) {
                        reject(err);
                    } else {
                        resolve(null);
                    }
                });
            } else {
                resolve(null);
            }
        });
    }

    kickClients() {
        if (!this.socketServer) return;
        this.socketServer.sockets.sockets.forEach(socket => {
            socket.disconnect();
        });
    }

    async stop(): Promise<void> {
        this.log.info("Stopping HTTP Service...");

        try {
            await this.closeSocket();
        } catch (ex: any) {
            if (ex.message !== "Server is not running.") {
                this.log.info(`Failed to close Socket server: ${ex.message}`);
            }
        }

        try {
            await this.closeHttp();
        } catch (ex: any) {
            if (ex.message !== "Server is not running.") {
                this.log.info(`Failed to close HTTP server: ${ex.message}`);
            }
        }
    }

    /**
     * Restarts the Socket.IO connection with a new port
     *
     * @param port The new port to listen on
     */
    async restart(reinitialize = false): Promise<void> {
        await this.stop();
        if (reinitialize) this.initialize();
        await this.start();
    }
}
