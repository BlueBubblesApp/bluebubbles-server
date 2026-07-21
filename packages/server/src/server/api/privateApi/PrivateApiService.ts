import * as os from "os";
import * as net from "net";
import { Sema } from "async-sema";
import { clamp, isEmpty, isNotEmpty } from "@server/helpers/utils";
import { TransactionPromise, TransactionResult } from "@server/managers/transactionManager/transactionPromise";
import { TransactionManager } from "@server/managers/transactionManager";

import { MAX_PORT, MIN_PORT } from "./Constants";
import { EventData, PrivateApiEventHandler } from "./eventHandlers";
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
import { PrivateApiFindMyEventHandler } from "./eventHandlers/PrivateApiFindMyEventHandler";
import { Socket } from "../types";
import { v4 } from "uuid";
import { Loggable } from "../../lib/logging/Loggable";
import { JsonLineBuffer } from "./JsonLineBuffer";

const FIRST_MACOS_USER_IDENTIFIER = 501;
const MAX_SOCKET_RESTART_ATTEMPTS = 5;
const SOCKET_LISTEN_BACKLOG = 511;
const SOCKET_WRITE_RELEASE_DELAY_MS = 200;
const socketWriteLock = new Sema(1);

export class PrivateApiService extends Loggable {
    tag = "PrivateApiService";

    server: net.Server;

    connectedClients: Socket[] = [];

    clientsByProcessIdentifier: Record<string, Socket> = {};

    socketRestartCount = 0;

    isRestarting = false;

    transactionManager: TransactionManager;

    eventHandlers: PrivateApiEventHandler[];

    mode: PrivateApiMode;

    modeType: PrivateApiModeConstructor;

    static get port(): number {
        return clamp(MIN_PORT + os.userInfo().uid - FIRST_MACOS_USER_IDENTIFIER, MIN_PORT, MAX_PORT);
    }

    get helper(): boolean {
        return this.connectedClients.length > 0;
    }

    hasClient(processIdentifier?: string): boolean {
        if (!processIdentifier) return this.helper;
        const client = this.clientsByProcessIdentifier[processIdentifier];
        return client != null && !client.destroyed;
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
        super();
        this.socketRestartCount = 0;
        this.transactionManager = new TransactionManager();

        this.eventHandlers = [
            new PrivateApiTypingEventHandler(),
            new PrivateApiPingEventHandler(),
            new PrivateApiAddressEventHandler(),
            new PrivateApiFaceTimeStatusHandler(),
            new PrivateApiFindMyEventHandler()
        ];
    }

    async start(): Promise<void> {
        this.log.debug("Starting Private API Helper Services...");
        await this.configureServer();

        this.log.info(`Starting socket server on port ${PrivateApiService.port}`);
        this.server.listen(PrivateApiService.port, "localhost", SOCKET_LISTEN_BACKLOG, () => {
            this.socketRestartCount = 0;
        });

        await this.startPerMode();
    }

    async startPerMode(): Promise<void> {
        try {
            const mode = "process-dylib";
            if (mode === "process-dylib") {
                this.modeType = ProcessDylibMode;
            } else {
                this.log.info(`Invalid Private API mode: ${mode}`);
                return;
            }

            await this.modeType.install();
            this.mode = new this.modeType();
            await this.mode.start();
        } catch (error: any) {
            this.log.error(`Failed to start Private API: ${error?.message ?? String(error)}`);
            return;
        }
    }

    private getProcessIdentifierForSocket(socketId: string): string | null {
        for (const processIdentifier of Object.keys(this.clientsByProcessIdentifier)) {
            if (this.clientsByProcessIdentifier[processIdentifier].id === socketId) {
                return processIdentifier;
            }
        }

        return null;
    }

    registerClient(processIdentifier: string, socket: Socket) {
        this.clientsByProcessIdentifier[processIdentifier] = socket;
        this.emit("client-registered", { process: processIdentifier, socket });
    }

    addClient(client: Socket) {
        this.connectedClients.push(client);
        this.log.info(`Added socket client (Total: ${this.connectedClients.length})`);
    }

    removeClient(client: Socket) {
        const processIdentifier = this.getProcessIdentifierForSocket(client.id);
        this.log.debug(`Private API Helper (${processIdentifier ?? "Anonymous"}) disconnected!`);

        const clientIndex = this.connectedClients.indexOf(client);
        if (clientIndex !== -1) {
            this.connectedClients.splice(clientIndex, 1);
            this.log.info(`Removed socket client (Total: ${this.connectedClients.length})`);
        }

        if (processIdentifier) {
            delete this.clientsByProcessIdentifier[processIdentifier];
        }
    }

    async configureServer(): Promise<void> {
        return new Promise<void>(resolve => {
            this.server = net.createServer((client: net.Socket) => {
                const socketId = v4();
                const socket = client as Socket;
                socket.setDefaultEncoding("utf8");
                socket.id = socketId;

                this.addClient(socket);
                this.log.info(`Private API Helper connected (UUID: ${socketId})!`);
                this.setupListeners(socket);

                socket.on("close", hadError => {
                    this.log.debug(`Socket Closed (${socketId}). Had Error: ${hadError}`);
                    this.removeClient(socket);
                });

                socket.on("end", () => {
                    this.log.debug(`Socket Ended by Client (${socketId})`);
                });

                socket.on("error", error => {
                    this.log.debug("An error occurred in a BlueBubbles Private API Helper connection! Closing...");
                    this.log.debug(String(error));
                    socket.destroy();
                });
            });

            this.server.on("error", error => {
                this.log.warn("An error occurred in the TCP Socket! Restarting");
                this.log.warn(error.toString());

                if (this.socketRestartCount < MAX_SOCKET_RESTART_ATTEMPTS) {
                    this.socketRestartCount += 1;
                    this.restart();
                } else {
                    this.log.info("Max restart count reached for Private API listener...");
                    this.stop();
                }
            });

            resolve();
        });
    }

    async onEvent(serializedMessage: string, socket: net.Socket): Promise<void> {
        if (!serializedMessage) {
            this.log.info("Received empty data from BlueBubblesHelper");
            return;
        }

        let message: NodeJS.Dict<any>;
        try {
            message = JSON.parse(serializedMessage);
        } catch (error) {
            this.log.info(`Failed to decode BlueBubblesHelper data: ${String(error)}`);
            return;
        }

        if (message == null || typeof message !== "object" || Array.isArray(message)) {
            this.log.warn("BlueBubblesHelper sent invalid data");
            return;
        }

        if (message.transactionId) {
            try {
                const transactionIndex = this.transactionManager.findIndex(message.transactionId);
                if (transactionIndex >= 0) {
                    const transaction = this.transactionManager.promises[transactionIndex];
                    if (isNotEmpty(message.error ?? "")) {
                        transaction.reject(message.error);
                    } else {
                        transaction.resolve(message.identifier, this.extractTransactionData(message));
                    }
                }
            } catch (error: any) {
                this.log.info(`Failed to handle transaction! Error: ${error?.message ?? String(error)}`);
            }
        } else if (message.event) {
            for (const eventHandler of this.eventHandlers) {
                try {
                    if (eventHandler.types.includes(message.event)) {
                        await eventHandler.handle(message as EventData, socket);
                    }
                } catch (error: any) {
                    this.log.info(
                        `Failed to handle event, '${message.event}'! Error: ${error?.message ?? String(error)}`
                    );
                }
            }
        }
    }

    setupListeners(socket: net.Socket) {
        const messageBuffer = new JsonLineBuffer();
        let messageProcessingQueue = Promise.resolve();

        socket.on("data", (chunk: Buffer | string) => {
            try {
                for (const serializedMessage of messageBuffer.append(chunk)) {
                    messageProcessingQueue = messageProcessingQueue
                        .then(() => this.onEvent(serializedMessage, socket))
                        .catch((error: any) => {
                            this.log.warn(`Failed to process Private API message: ${error?.message ?? String(error)}`);
                        });
                }
            } catch (error: any) {
                this.log.warn(`Failed to buffer Private API message: ${error?.message ?? String(error)}`);
                socket.destroy();
            }
        });
    }

    private extractTransactionData(response: NodeJS.Dict<any>) {
        if (isNotEmpty(response?.data)) return response.data;

        const transactionData = { ...response };
        const envelopeKeys = ["transactionId", "error", "identifier"];
        for (const envelopeKey of envelopeKeys) {
            delete transactionData[envelopeKey];
        }

        return isEmpty(transactionData) ? null : transactionData;
    }

    async writeData(
        action: string,
        payload: NodeJS.Dict<any>,
        transaction?: TransactionPromise,
        targetProcessIdentifier?: string
    ): Promise<TransactionResult> {
        const failureMessage = "Failed to send request to Private API!";
        await socketWriteLock.acquire();

        try {
            if (transaction) {
                this.transactionManager.add(transaction);
            }

            await new Promise<void>((resolve, reject) => {
                const requestMessage: NodeJS.Dict<any> = { action, data: payload };

                if (transaction) {
                    requestMessage.transactionId = transaction.transactionId;
                }

                this.writeToClients(`${JSON.stringify(requestMessage)}\n`, targetProcessIdentifier).then(success => {
                    if (success) return resolve();
                    reject();
                });
            });

            if (transaction) {
                return transaction.promise;
            }
        } catch (error: any) {
            this.log.debug(`${failureMessage} ${error?.message ?? error}`);
        } finally {
            setTimeout(() => socketWriteLock.release(), SOCKET_WRITE_RELEASE_DELAY_MS);
        }

        return null;
    }

    private async writeToClients(data: string, targetProcessIdentifier?: string): Promise<boolean> {
        if (targetProcessIdentifier) {
            const client = this.clientsByProcessIdentifier[targetProcessIdentifier];
            if (!client) return false;
            await this.writeToClient(client, data);
            return true;
        }

        let success = false;
        for (const client of this.connectedClients) {
            try {
                await this.writeToClient(client, data);
                success = true;
            } catch {
                continue;
            }
        }

        return success;
    }

    private async writeToClient(client: net.Socket, data: string): Promise<void> {
        return new Promise((resolve, reject) => {
            client.write(data, (error: Error) => {
                if (error) {
                    this.log.info(`Socket write error: ${error?.message ?? String(error)}`);
                    reject(error);
                } else {
                    resolve();
                }
            });
        });
    }

    destroySocketClients() {
        for (const client of this.connectedClients) {
            if (client.destroyed) continue;
            client.destroy();
        }

        this.connectedClients = [];
        this.clientsByProcessIdentifier = {};
    }

    async restart(): Promise<void> {
        // Guard against overlapping restarts (e.g. multiple rapid "error" events
        // on the socket server), which would otherwise race on this.server/this.mode.
        if (this.isRestarting) return;
        this.isRestarting = true;

        try {
            await this.stop();
            await this.start();
        } finally {
            this.isRestarting = false;
        }
    }

    async stop() {
        this.log.info(`Stopping Private API Helper...`);

        try {
            this.destroySocketClients();
        } catch (error: any) {
            this.log.debug(`Failed to stop Private API Helpers! Error: ${error.toString()}`);
        }

        try {
            if (this.server) {
                this.server.removeAllListeners();
                this.server.close();
                this.server = null;
            }
        } catch (error: any) {
            this.log.debug(`Failed to stop Private API Helper! Error: ${error.toString()}`);
        }

        await this.mode?.stop();
        this.log.info(`Private API Helper Stopped...`);
    }
}
