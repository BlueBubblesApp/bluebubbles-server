/* eslint-disable max-len */
import { Server as SocketServer, ServerOptions } from "socket.io";

// HTTP libraries
import KoaApp from "koa";
import koaBody from "koa-body";
import koaJson from "koa-json";
import KoaRouter from "koa-router";
import koaCors from "koa-cors";
import * as https from "https";
import * as http from "http";
import * as fs from "fs";

// Internal libraries
import { Server } from "@server";
import { isNotEmpty, onlyAlphaNumeric, safeTrim } from "@server/helpers/utils";
import { EventCache } from "@server/eventCache";
import { CertificateService } from "@server/services/certificateService";

import { HttpRoutes as HttpRoutesV1 } from "./api/v1/httpRoutes";
import { SocketRoutes as SocketRoutesV1 } from "./api/v1/socketRoutes";
import { ErrorMiddleware } from "./api/v1/middleware/errorMiddleware";
import { createServerErrorResponse } from "./api/v1/responses";
import { HELLO_WORLD } from "@server/events";
import { ScheduledService } from "../../lib/ScheduledService";
import { Loggable } from "../../lib/logging/Loggable";
import { ProxyServices } from "@server/databases/server/constants";
import { ProcessSpawner } from "@server/lib/ProcessSpawner";

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
        transports: ["websocket", "polling"]
    };

    httpOpts: any;

    sendCache: EventCache;

    clearCacheService: ScheduledService;

    portCheckerService: ScheduledService;

    initialize() {
        this.httpOpts = {};

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

        // This is used here so that we can catch errors in KoaBody as well
        this.koaApp.use(ErrorMiddleware);

        // Increase size limits from the default 1mb
        this.koaApp.use(
            koaBody({
                jsonLimit: "100mb",
                textLimit: "100mb",
                formLimit: "1024mb",
                multipart: true,
                parsedMethods: ["POST", "PUT", "PATCH", "DELETE"],
                formidable: {
                    // 1GB (1024 b * 1024 kb * 1024 mb)
                    maxFileSize: 1024 * 1024 * 1024 // Defaults to 200mb
                }
            })
        );

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
     * Checks to see if another process is listening on the socket port.
     */
    async checkIfPortInUse(port: number) {
        try {
            // Check if there are any listening services
            const output = await ProcessSpawner.executeCommand('lsof', [
                '-nP',
                '-iTCP',
                '-sTCP:LISTEN',
                '|',
                'grep',
                `${port}`
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

            let pass = socket.handshake.query?.password ?? socket.handshake.query?.guid;
            const cfgPass = String((await Server().repo.getConfig("password")) as string);

            // Decode the param incase it contains URL encoded characters
            pass = decodeURI(pass as string);

            // Basic authentication
            if (safeTrim(pass) === safeTrim(cfgPass)) {
                this.log.info(
                    `Client Authenticated Successfully (Total Clients: ${this.socketServer.sockets.sockets.size})`
                );
            } else {
                socket.disconnect();
                this.log.info(`Closing client connection. Authentication failed.`);
            }

            /**
             * Error handling middleware for all Socket.IO requests.
             * If there are any errors in a socket event, they will be handled here.
             *
             * A console message will be printed, and a socket error will be emitted
             */
            socket.use(async (_: any, next: (error?: Error) => void) => {
                try {
                    await next();
                } catch (ex: any) {
                    this.log.error(`Socket server error! ${ex.message}`);
                    socket.emit("exception", createServerErrorResponse(ex?.message ?? ex));
                    next(ex);
                }
            });

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
