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
import { FileSystem } from "@server/fileSystem";
import { isNotEmpty, onlyAlphaNumeric, safeTrim } from "@server/helpers/utils";
import { EventCache } from "@server/eventCache";
import { CertificateService } from "@server/services/certificateService";

import { HttpRoutes as HttpRoutesV1 } from "./api/v1/httpRoutes";
import { SocketRoutes as SocketRoutesV1 } from "./api/v1/socketRoutes";
import { ErrorMiddleware } from "./api/v1/middleware/errorMiddleware";
import { createServerErrorResponse } from "./api/v1/responses";
import { HELLO_WORLD } from "@server/events";

/**
 * This service class handles all routing for incoming socket
 * connections and requests.
 */
export class HttpService {
    koaApp: KoaApp;

    httpServer: https.Server | http.Server;

    socketServer: SocketServer;

    socketOpts: Partial<ServerOptions> = {
        pingTimeout: 1000 * 60 * 2, // 2 Minute ping timeout
        pingInterval: 1000 * 30, // 30 Second ping interval
        upgradeTimeout: 1000 * 30, // 30 Seconds

        // 100 MB. 1000 == 1kb. 1000 * 1000 == 1mb
        maxHttpBufferSize: 1000 * 1000 * 100,
        allowEIO3: true,
        transports: ["websocket", "polling"]
    };

    httpOpts: any;

    sendCache: EventCache;

    initialize() {
        this.httpOpts = {};

        // Configure certificates
        try {
            const use_custom_cert = Server().repo.getConfig("use_custom_certificate") as boolean;
            const proxy_service = Server().repo.getConfig("proxy_service") as string;
            if (onlyAlphaNumeric(proxy_service).toLowerCase() === "dynamicdns") {
                if (use_custom_cert) {
                    // Only setup certs if the proxy service is
                    Server().log("Starting Certificate service...");
                    CertificateService.start();

                    // Add the SSL/TLS PEMs to the opts
                    this.httpOpts.cert = fs.readFileSync(CertificateService.certPath);
                    this.httpOpts.key = fs.readFileSync(CertificateService.keyPath);
                }
            }
        } catch (ex: any) {
            Server().log(`Failed to start Certificate service! ${ex.message}`, "error");
        }

        // Create the HTTP server
        this.koaApp = new KoaApp();
        this.configureKoa();

        if (this.httpOpts.cert && this.httpOpts.key) {
            Server().log("Starting up HTTPS Server...");
            this.httpServer = https.createServer(this.httpOpts, this.koaApp.callback());
        } else {
            Server().log("Starting up HTTP Server...");
            this.httpServer = http.createServer(this.koaApp.callback());
        }

        // Create the socket server and link the http context
        this.socketServer = new SocketServer(this.httpServer, this.socketOpts);
        this.sendCache = new EventCache();
        this.startStatusListener();

        // Every 6 hours, clear the send cache
        setInterval(() => {
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
                formLimit: "1000mb",
                multipart: true,
                parsedMethods: ['POST', 'PUT', 'PATCH', 'DELETE']
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
     * Checks to see if we are currently listening
     */
    startStatusListener() {
        setInterval(async () => {
            const port = Server().repo.getConfig("socket_port");

            try {
                // Check if there are any listening services
                let res = (await FileSystem.execShellCommand(`lsof -nP -iTCP -sTCP:LISTEN | grep ${port}`)) as string;
                res = safeTrim(res);

                // If the result doesn't show anything listening,
                if (!res.includes(port.toString())) {
                    Server().log("Socket not listening! Restarting...", "error");
                    this.restart();
                }
            } catch {
                // Don't show an error, I believe this throws a "false error".
                // For instance, if the proxy service doesn't start, and the command returns
                // nothing, it thinks it's an actual error, which it isn't
            }
        }, 1000 * 60); // Check every minute
    }

    /**
     * Creates the initial connection handler for Socket.IO
     */
    start() {
        if (!this.socketServer) return;

        /**
         * Handle all other data requests
         */
        this.socketServer.on("connection", async socket => {
            socket.on("disconnect", (_: any) => {
                Server().log(`Client disconnected (Total Clients: ${this.socketServer.sockets.sockets.size})`);
            });

            let pass = socket.handshake.query?.password ?? socket.handshake.query?.guid;
            const cfgPass = String((await Server().repo.getConfig("password")) as string);

            // Decode the param incase it contains URL encoded characters
            pass = decodeURI(pass as string);

            // Basic authentication
            if (safeTrim(pass) === safeTrim(cfgPass)) {
                Server().log(
                    `Client Authenticated Successfully (Total Clients: ${this.socketServer.sockets.sockets.size})`
                );
            } else {
                socket.disconnect();
                Server().log(`Closing client connection. Authentication failed.`);
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
                    Server().log(`Socket server error! ${ex.message}`, "error");
                    socket.emit("exception", createServerErrorResponse(ex?.message ?? ex));
                    next(ex);
                }
            });

            // Pass to method to handle the socket events
            SocketRoutesV1.createRoutes(socket);
        });

        // Start the server
        this.httpServer.listen(Server().repo.getConfig("socket_port") as number, () => {
            Server().log(`Successfully started HTTP${isNotEmpty(this.httpOpts) ? "S" : ""} server`);

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
        Server().log("Stopping HTTP Service...");

        try {
            await this.closeSocket();
        } catch (ex: any) {
            if (ex.message !== "Server is not running.") {
                Server().log(`Failed to close Socket server: ${ex.message}`);
            }
        }

        try {
            await this.closeHttp();
        } catch (ex: any) {
            if (ex.message !== "Server is not running.") {
                Server().log(`Failed to close HTTP server: ${ex.message}`);
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
