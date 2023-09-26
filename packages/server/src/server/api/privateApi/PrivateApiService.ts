import "zx/globals";
import * as os from "os";
import * as net from "net";
import { Server } from "@server";
import { clamp, isEmpty, isNotEmpty } from "@server/helpers/utils";
import {
    TransactionPromise,
    TransactionResult,
} from "@server/managers/transactionManager/transactionPromise";
import { TransactionManager } from "@server/managers/transactionManager";

import { MAX_PORT, MIN_PORT } from "./Constants";
import { PrivateApiEventHandler } from "./eventHandlers";
import { PrivateApiTypingEventHandler } from "./eventHandlers/PrivateApiTypingEventHandler";
import { PrivateApiMessage } from "./apis/PrivateApiMessage";
import { PrivateApiChat } from "./apis/PrivateApiChat";
import { PrivateApiHandle } from "./apis/PrivateApiHandle";
import { PrivateApiAttachment } from "./apis/PrivateApiAttachment";
import { PrivateApiMode, PrivateApiModeConstructor } from "./modes";
import { ProcessDylibMode } from "./modes/ProcessDylibMode";
import { PrivateApiPingEventHandler } from "./eventHandlers/PrivateApiPingEventHandler";
import { PrivateApiFindMy } from "./apis/PrivateApiFindMy";
import { PrivateApiAddressEventHandler } from "./eventHandlers/PrivateApiAddressEventHandler";
import { PrivateApiFaceTimeStatusHandler } from "./eventHandlers/PrivateApiFaceTimeStatusHandler";
import { PrivateApiCloud } from "./apis/PrivateApiCloud";
import { PrivateApiFaceTime } from "./apis/PrivateApiFaceTime";
import { LogLevel } from "electron-log";


export class PrivateApiService {
    server: net.Server;

    clients: net.Socket[] = [];

    restartCounter = 0;

    transactionManager: TransactionManager;

    eventHandlers: PrivateApiEventHandler[];

    mode: PrivateApiMode;

    modeType: PrivateApiModeConstructor;

    static get port(): number {
        return clamp(MIN_PORT + os.userInfo().uid - 501, MIN_PORT, MAX_PORT);
    }

    // Backwards compatibility getter.
    // Eventually, we probably want to remove this alias
    get helper(): boolean {
        return this.clients.length > 0;
    }

    get message(): PrivateApiMessage {
        return new PrivateApiMessage(this);
    }

    get chat(): PrivateApiChat {
        return new PrivateApiChat(this);
    }

    get handle(): PrivateApiHandle {
        return new PrivateApiHandle(this);
    }

    get attachment(): PrivateApiAttachment {
        return new PrivateApiAttachment(this);
    }

    get findmy(): PrivateApiFindMy {
        return new PrivateApiFindMy(this);
    }

    get cloud(): PrivateApiCloud {
        return new PrivateApiCloud(this);
    }

    get facetime(): PrivateApiFaceTime {
        return new PrivateApiFaceTime(this);
    }

    constructor() {
        this.restartCounter = 0;
        this.transactionManager = new TransactionManager();

        // Register the event handlers
        this.eventHandlers = [
            new PrivateApiTypingEventHandler(),
            new PrivateApiPingEventHandler(),
            new PrivateApiAddressEventHandler(),
            new PrivateApiFaceTimeStatusHandler()
        ];
    }

    log(message: string, level: LogLevel = 'info') {
        Server().log(`[PrivateApiService] ${String(message)}`, level);
    }

    async start(): Promise<void> {
        // Configure & start the listener
        this.log("Starting Private API Helper Services...", "debug");
        this.configureServer();

        // we need to get the port to open the server on (to allow multiple users to use the bundle)
        // we'll base this off the users uid (a unique id for each user, starting from 501)
        // we'll subtract 501 to get an id starting at 0, incremented for each user
        // then we add this to the base port to get a unique port for the socket
        this.log(`Starting socket server on port ${PrivateApiService.port}`);
        this.server.listen(PrivateApiService.port, "localhost", 511, () => {
            this.restartCounter = 0;
        });

        this.startPerMode();
    }

    async startPerMode(): Promise<void> {
        try {
            const mode = 'process-dylib'
            if (mode === 'process-dylib') {
                this.modeType = ProcessDylibMode;
            } else {
                this.log(`Invalid Private API mode: ${mode}`);
                return;
            }

            await this.modeType.install();
            this.mode = new this.modeType();
            await this.mode.start();
        } catch (ex: any) {
            this.log(`Failed to start Private API: ${ex?.message ?? String(ex)}`, "error");
            return;
        }
    }

    addClient(client: net.Socket) {
        this.clients.push(client);
        this.log(`Added socket client (Total: ${this.clients.length})`);
    }

    removeClient(client: net.Socket) {
        const idx = this.clients.indexOf(client);
        if (idx !== -1) {
            this.clients.splice(idx, 1);
            this.log(`Removed socket client (Total: ${this.clients.length})`);
        }
    }

    configureServer() {
        this.server = net.createServer((socket: net.Socket) => {
            this.addClient(socket);
            socket.setDefaultEncoding("utf8");

            this.log("Private API Helper connected!");
            this.setupListeners(socket);

            socket.on("close", () => {
                this.log("Private API Helper disconnected!", "debug");
                this.removeClient(socket);
            });

            socket.on("error", () => {
                this.log("An error occured in the BlueBubblesHelper connection! Closing...", "error");
                socket.destroy();
            });
        });

        this.server.on("error", err => {
            this.log("An error occured in the TCP Socket! Restarting", "error");
            this.log(err.toString(), "error");

            if (this.restartCounter <= 5) {
                this.restartCounter += 1;
                this.start();
            } else {
                this.log("Max restart count reached for Private API listener...");
            }
        });
    }

    

    async onEvent(eventRaw: string): Promise<void> {
        if (eventRaw == null) {
            this.log(`Received null data from BlueBubblesHelper!`);
            return;
        }

        // Data can contain multiple events, each split by the demiliter (\n)
        const eventData: string[] = String(eventRaw).split("\n");
        const uniqueEvents = [...new Set(eventData)];
        for (const event of uniqueEvents) {
            if (!event || event.trim().length === 0) continue;
            if (event == null) {
                this.log(`Failed to decode null BlueBubblesHelper data!`);
                continue;
            }

            // this.log(`Received data from BlueBubblesHelper: ${event}`, "debug");
            let data;

            // Handle in a timeout so that we handle each event asyncronously
            try {
                data = JSON.parse(event);
            } catch (e) {
                this.log(`Failed to decode BlueBubblesHelper data! ${event}, ${e}`);
                return;
            }

            if (data == null) {
                this.log("BlueBubblesHelper sent null data", "warn");
                return;
            }

            if (data.transactionId) {
                // Resolve the promise from the transaction manager
                const idx = this.transactionManager.findIndex(data.transactionId);
                if (idx >= 0) {
                    if (isNotEmpty(data?.error ?? "")) {
                        this.transactionManager.promises[idx].reject(data.error);
                    } else {
                        const result = this.readTransactionData(data);
                        this.transactionManager.promises[idx].resolve(data.identifier, result);
                    }
                }
            } else if (data.event) {
                for (const eventHandler of this.eventHandlers) {
                    if (eventHandler.types.includes(data.event)) {
                        await eventHandler.handle(data);
                    }
                }
            }
        }
    }

    setupListeners(socket: net.Socket) {
        socket.on("data", this.onEvent.bind(this));
    }

    private readTransactionData(response: NodeJS.Dict<any>) {
        // If there is a non-empty data key, return that
        if (isNotEmpty(response?.data)) return response.data;

        // Otherwise, strip the "standard" keys and return the rest as the data
        const data = { ...response };
        const stripKeys = ["transactionId", "error", "identifier"];
        for (const key of stripKeys) {
            if (Object.keys(data).includes(key)) {
                delete data[key];
            }
        }

        // Return null if there is no data
        if (isEmpty(data)) return null;
        return data;
    }

    async writeData(
        action: string,
        data: NodeJS.Dict<any>,
        transaction?: TransactionPromise
    ): Promise<TransactionResult> {
        const msg = "Failed to send request to Private API!";

        // If we have a transaction, add it to the manager
        if (transaction) {
            this.transactionManager.add(transaction);
        }

        try {
            await new Promise<void>((resolve, reject) => {
                const d: NodeJS.Dict<any> = { action, data };

                // If we have a transaction, set the transaction ID for the request
                if (transaction) {
                    d.transactionId = transaction.transactionId;
                }

                // For each ocket client, write data
                this.writeToClients(`${JSON.stringify(d)}\n`).then((success) => {
                    if (success) return resolve();
                    reject();
                });
            });

            // If we have a transaction, wait until the transaction is fulfilled to return
            if (transaction) {
                return transaction.promise;
            }
        } catch (ex: any) {
            this.log(`${msg} ${ex?.message ?? ex}`, "debug");
        }

        return null;
    }

    private async writeToClients(data: string): Promise<boolean> {
        let success = false;
        for (const client of this.clients) {
            try {
                await this.writeToClient(client, data);
                success = true;
            } catch {
                // Do nothing
            }
        }

        // We are successful if at least one helper gets the message
        return success;
    }

    private async writeToClient(client: net.Socket, data: string): Promise<void> {
        return new Promise((resolve, reject) => {
            client.write(data, (err: Error) => {
                if (err) {
                    this.log(`Socket write error: ${err?.message ?? String(err)}`);
                    reject(err);
                } else {
                    resolve();
                }
            });
        });
    }

    destroySocketClients() {
        for (const client of this.clients) {
            if (client.destroyed) continue;
            client.destroy();
        }

        this.clients = [];
    }

    async restart(): Promise<void> {
        await this.stop();
        await this.start();
    }

    async stop() {
        this.log(`Stopping Private API Helper...`);

        try {
            this.destroySocketClients();
        } catch (ex: any) {
            this.log(`Failed to stop Private API Helpers! Error: ${ex.toString()}`, 'debug');
        }

        try {
            if (this.server && this.server.listening) {
                this.log("Stopping Private API Helper...", "debug");

                this.server.removeAllListeners();
                this.server.close();
                this.server = null;
            }
        } catch (ex: any) {
            this.log(`Failed to stop Private API Helper! Error: ${ex.toString()}`, 'debug');
        }

        await this.mode?.stop();
    }
}
