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
import { PrivateApiCloud } from "./apis/PrivateApiCloud";


export class PrivateApiService {
    server: net.Server;

    helper: net.Socket;

    restartCounter: number;

    transactionManager: TransactionManager;

    eventHandlers: PrivateApiEventHandler[];

    mode: PrivateApiMode;

    modeType: PrivateApiModeConstructor;

    static get port(): number {
        return clamp(MIN_PORT + os.userInfo().uid - 501, MIN_PORT, MAX_PORT);
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

    constructor() {
        this.restartCounter = 0;
        this.transactionManager = new TransactionManager();

        // Register the event handlers
        this.eventHandlers = [
            new PrivateApiTypingEventHandler(),
            new PrivateApiPingEventHandler(),
            new PrivateApiAddressEventHandler(),
        ];
    }

    async start(): Promise<void> {
        // Configure & start the listener
        Server().log("Starting Private API Helper...", "debug");
        this.configureServer();

        // we need to get the port to open the server on (to allow multiple users to use the bundle)
        // we'll base this off the users uid (a unique id for each user, starting from 501)
        // we'll subtract 501 to get an id starting at 0, incremented for each user
        // then we add this to the base port to get a unique port for the socket
        Server().log(`Starting Socket server on port ${PrivateApiService.port}`);
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
                Server().log(`Invalid Private API mode: ${mode}`);
                return;
            }

            await this.modeType.install();
            this.mode = new this.modeType();
            await this.mode.start();
        } catch (ex: any) {
            Server().log(`Failed to start Private API: ${ex?.message ?? String(ex)}`, "error");
            return;
        }
    }

    configureServer() {
        this.server = net.createServer((socket: net.Socket) => {
            this.helper = socket;
            this.helper.setDefaultEncoding("utf8");

            Server().log("Private API Helper connected!");
            this.setupListeners();

            this.helper.on("close", () => {
                Server().log("Private API Helper disconnected!", "debug");
                this.helper = null;
            });

            this.helper.on("error", () => {
                Server().log("An error occured in the BlueBubblesHelper connection! Closing...", "error");
                if (this.helper) this.helper.destroy();
            });
        });

        this.server.on("error", err => {
            Server().log("An error occured in the TCP Socket! Restarting", "error");
            Server().log(err.toString(), "error");

            if (this.restartCounter <= 5) {
                this.restartCounter += 1;
                this.start();
            } else {
                Server().log("Max restart count reached for Private API listener...");
            }
        });
    }

    

    async onEvent(eventRaw: string): Promise<void> {
        if (eventRaw == null) {
            Server().log(`Received null data from BlueBubblesHelper!`);
            return;
        }

        // Data can contain multiple events, each split by the demiliter (\n)
        const eventData: string[] = String(eventRaw).split("\n");
        const uniqueEvents = [...new Set(eventData)];
        for (const event of uniqueEvents) {
            if (!event || event.trim().length === 0) continue;
            if (event == null) {
                Server().log(`Failed to decode null BlueBubblesHelper data!`);
                continue;
            }

            // Server().log(`Received data from BlueBubblesHelper: ${event}`, "debug");
            let data;

            // Handle in a timeout so that we handle each event asyncronously
            try {
                data = JSON.parse(event);
            } catch (e) {
                Server().log(`Failed to decode BlueBubblesHelper data! ${event}, ${e}`);
                return;
            }

            if (data == null) {
                Server().log("BlueBubblesHelper sent null data", "warn");
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

    setupListeners() {
        this.helper.on("data", this.onEvent.bind(this));
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
            await new Promise((resolve, reject) => {
                const d: NodeJS.Dict<any> = { action, data };

                // If we have a transaction, set the transaction ID for the request
                if (transaction) {
                    d.transactionId = transaction.transactionId;
                }

                // Write the request to the socket
                const res = this.helper.write(`${JSON.stringify(d)}\n`, (err: Error) => {
                    if (err) {
                        Server().log(`Socket write error: ${err?.message ?? String(err)}`);
                        reject(err);
                    }
                });

                if (!res) {
                    reject(new Error("Unable to write to TCP Socket."));
                } else {
                    resolve(res);
                }
            });

            // If we have a transaction, wait until the transaction is fulfilled to return
            if (transaction) {
                return transaction.promise;
            }
        } catch (ex: any) {
            Server().log(`${msg} ${ex?.message ?? ex}`, "debug");
        }

        return null;
    }

    async restart(): Promise<void> {
        await this.stop();
        await this.start();
    }

    async stop() {
        Server().log(`Stopping Private API Helper...`);

        try {
            if (this.helper && !this.helper.destroyed) {
                this.helper.destroy();
                this.helper = null;
            }
        } catch (ex: any) {
            Server().log(`Failed to stop Private API Helper! Error: ${ex.toString()}`, 'debug');
        }

        try {
            if (this.server && this.server.listening) {
                Server().log("Stopping Private API Helper...", "debug");

                this.server.removeAllListeners();
                this.server.close();
                this.server = null;
            }
        } catch (ex: any) {
            Server().log(`Failed to stop Private API Helper! Error: ${ex.toString()}`, 'debug');
        }

        await this.mode?.stop();
    }
}
