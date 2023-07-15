import "zx/globals";
import * as path from "path";
import * as os from "os";
import * as fs from "fs";
import * as net from "net";
import CompareVersions from "compare-versions";
import cpr from "recursive-copy";
import { parse as ParsePlist } from "plist";
import { ProcessPromise } from "zx";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { clamp, isEmpty, isMinBigSur, isMinMonterey, isNotEmpty, waitMs } from "@server/helpers/utils";
import { restartMessages, stopMessages } from "@server/api/v1/apple/scripts";
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

type BundleStatus = {
    success: boolean;
    message: string;
};

export class PrivateApiService {
    server: net.Server;

    helper: net.Socket;

    isStopping = false;

    restartCounter: number;

    transactionManager: TransactionManager;

    dylibProcess: ProcessPromise<any>;

    dylibFailureCounter: number;

    dylibLastErrorTime: number;

    eventHandlers: PrivateApiEventHandler[];

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

    constructor() {
        this.restartCounter = 0;
        this.transactionManager = new TransactionManager();

        // Register the event handlers
        this.eventHandlers = [
            new PrivateApiTypingEventHandler()
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
            const mode = (Server().repo.getConfig("private_api_mode") as string) ?? 'macforge';
            if (mode === 'macforge') {
                await this.startMacForge();
            } else if (mode === 'process-dylib') {
                await this.startProcessDylib();
            } else {
                Server().log(`Invalid Private API mode: ${mode}`);
                return;
            }
        } catch (ex: any) {
            Server().log(`Failed to start Private API: ${ex?.message ?? String(ex)}`, "error");
            return;
        }
    }

    async startMacForge(): Promise<void> {
        await PrivateApiService.installBundle();
    }

    async startProcessDylib(): Promise<void> {
        // Uninstall any previously installed MacForge bundles
        await PrivateApiService.uninstallBundle();

        // Clear the markers
        this.dylibFailureCounter = 0;
        this.dylibLastErrorTime = 0;

        const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";
        const localPath = path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.dylib");
        if (!fs.existsSync(localPath)) {
            await Server().repo.setConfig("private_api_mode", "macforge");
            throw new Error("Unable to locate embedded Private API DYLIB! Falling back to MacForge Bundle.");
        }

        const messagesPath = "/System/Applications/Messages.app/Contents/MacOS/Messages";
        if (!fs.existsSync(messagesPath)) {
            await Server().repo.setConfig("private_api_mode", "macforge");
            throw new Error("Unable to locate Messages.app! Falling back to MacForge Bundle.");
        }

        // If there are 5 failures in a row, we'll stop trying to start it
        while (this.dylibFailureCounter < 5) {
            try {
                // Stop the running Messages app
                try {
                    await FileSystem.executeAppleScript(stopMessages());
                    await waitMs(1000);
                } catch {
                    // Ignore. This is most likely due to an osascript error.
                    // Which we don't want to stop the dylib from starting.
                }

                // Execute shell command to start the dylib.
                this.dylibProcess = $`DYLD_INSERT_LIBRARIES=${localPath} ${messagesPath}`;
                await this.dylibProcess;
            } catch (ex: any) {
                if (this.isStopping) return;

                // If the last time we errored was more than 15 seconds ago, reset the counter.
                // This would indicate that the dylib was running, but then crashed.
                // Rather than an immediate crash.
                if (Date.now() - this.dylibLastErrorTime > 15000) {
                    this.dylibFailureCounter = 0;
                }

                this.dylibFailureCounter += 1;
                this.dylibLastErrorTime = Date.now();
                if (this.dylibFailureCounter >= 5) {
                    Server().log(`Failed to start dylib after 5 tries: ${ex?.message ?? String(ex)}`, "error");
                }
            }
        }

        if (this.dylibFailureCounter >= 5) {
            Server().log("Failed to start Private API DYLIB 3 times in a row, giving up...", "error");
        }
    }

    static async installBundle(force = false): Promise<BundleStatus> {
        const status: BundleStatus = { success: false, message: "Unknown status" };

        // Make sure the Private API is enabled
        const pApiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        if (!force && !pApiEnabled) {
            status.message = "Private API feature is not enabled";
            return status;
        }

        // eslint-disable-next-line no-nested-ternary
        const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";
        const localPath = path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.bundle");
        const localInfo = path.join(localPath, "Contents/Info.plist");

        // If the local bundle doesn't exist, don't do anything
        if (!fs.existsSync(localPath)) {
            status.message = "Unable to locate embedded bundle";
            return status;
        }

        Server().log("Attempting to install Private API Helper Bundle...", "debug");

        // Write to all paths. For MySIMBL & MacEnhance, as well as their user/library variants
        // Technically, MacEnhance is only for Mojave+, however, users may have older versions installed
        // If we find any of the directories, we should install to them
        const opts = [
            FileSystem.libMacForgePlugins,
            // FileSystem.usrMacForgePlugins,
            FileSystem.libMySimblPlugins
            // FileSystem.usrMySimblPlugins
        ];

        // For each of the paths, write the bundle to them (assuming the paths exist & the bundle is newer)
        let writeCount = 0;
        for (const pluginPath of opts) {
            // If the MacForge/MySIMBL path exists, but the plugin path doesn't, create it.
            if (fs.existsSync(path.dirname(pluginPath)) && !fs.existsSync(pluginPath)) {
                Server().log("Plugins path does not exist, creating it...", "debug");
                try {
                    fs.mkdirSync(pluginPath, { recursive: true });
                } catch (ex: any) {
                    Server().log(`Failed to create Plugins path: ${ex?.message ?? String(ex)}`, "debug");
                }
            }

            if (!fs.existsSync(pluginPath)) continue;

            const remotePath = path.join(pluginPath, "BlueBubblesHelper.bundle");
            const remoteInfo = path.join(remotePath, "Contents/Info.plist");

            try {
                // If the remote bundle doesn't exist, we just need to write it
                if (force || !fs.existsSync(remotePath)) {
                    if (force) {
                        Server().log(`Private API Bundle force install. Writing to ${remotePath}`, "debug");
                    } else {
                        Server().log(`Private API Bundle does not exist. Writing to ${remotePath}`, "debug");
                    }

                    await cpr(localPath, remotePath, { overwrite: true, dot: true });
                } else {
                    // Pull the version for the local bundle
                    let parsed = ParsePlist(fs.readFileSync(localInfo).toString("utf-8"));
                    let metadata = JSON.parse(JSON.stringify(parsed)); // We have to do this to access the vars
                    const localVersion = metadata.CFBundleShortVersionString;

                    // Pull the version for the remote bundle
                    parsed = ParsePlist(fs.readFileSync(remoteInfo).toString("utf-8"));
                    metadata = JSON.parse(JSON.stringify(parsed)); // We have to do this to access the vars
                    const remoteVersion = metadata.CFBundleShortVersionString;

                    // Compare the local version to the remote version and overwrite if newer
                    if (CompareVersions(localVersion, remoteVersion) === 1) {
                        Server().log(`Private API Bundle has an update. Writing to ${remotePath}`, "debug");
                        await cpr(localPath, remotePath, { overwrite: true, dot: true });
                    } else {
                        Server().log(`Private API Bundle does not need to be updated`, "debug");
                    }
                }

                writeCount += 1;
            } catch (ex: any) {
                Server().log(`Failed to write to ${remotePath}: ${ex?.message ?? ex}`);
            }
        }

        // Print a log based on if we wrote the bundle anywhere
        if (writeCount === 0) {
            status.message =
                "Attempted to install helper bundle, but neither MySIMBL nor MacForge (MacEnhance) was found!";
            Server().log(status.message, "warn");
        } else {
            // Restart iMessage to "apply" the changes
            Server().log("Restarting iMessage to apply Helper updates...");
            await FileSystem.executeAppleScript(restartMessages());

            status.success = true;
            status.message = "Successfully installed latest Private API Helper Bundle!";
            Server().log(status.message);
        }

        return status;
    }

    static async uninstallBundle(): Promise<void> {
        Server().log("Attempting to uninstall Private API Helper Bundle...", "debug");

        // Remove from all paths. For MySIMBL & MacEnhance, as well as their user/library variants
        // Technically, MacEnhance is only for Mojave+, however, users may have older versions installed
        // If we find any of the directories, we should install to them
        const opts = [
            FileSystem.libMacForgePlugins,
            // FileSystem.usrMacForgePlugins,
            FileSystem.libMySimblPlugins
            // FileSystem.usrMySimblPlugins
        ];

        for (const pluginPath of opts) {
            if (!fs.existsSync(pluginPath)) continue;

            const remotePath = path.join(pluginPath, "BlueBubblesHelper.bundle");

            try {
                // If the remote bundle doesn't exist, we just need to write it
                if (fs.existsSync(remotePath)) {
                    fs.rmdirSync(remotePath, { recursive: true });
                }
            } catch (ex: any) {
                Server().log((
                    `Failed to remove MacForge bundle at, "${remotePath}": ` +
                    `Please manually remove it to prevent conflicts`
                ), 'warn');
            }
        }
    }

    configureServer() {
        this.server = net.createServer((socket: net.Socket) => {
            this.helper = socket;
            this.helper.setDefaultEncoding("utf8");

            this.setupListeners();
            this.helper.on("connect", () => {
                Server().log("Private API Helper connected!");
            });

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

    async waitForDylibDeath(): Promise<void> {
        if (this.dylibProcess == null) return;

        return new Promise((resolve, _) => {
            this.dylibProcess.finally(resolve);
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
        this.isStopping = true;
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

        let killedDylib = false;
        try {
            this.dylibFailureCounter = 0;
            this.restartCounter = 0;
            if (this.dylibProcess != null && !(this.dylibProcess?.child?.killed ?? false)) {
                Server().log("Killing BlueBubblesHelper DYLIB...", "debug");
                await this.dylibProcess.kill(9);
                killedDylib = true;
            }
        } catch (ex) {
            Server().log(`Failed to stop Private API Helper! Error: ${ex.toString()}`, 'debug');
        }

        // Wait for the dylib to die
        if (killedDylib) {
            await this.waitForDylibDeath();
        }

        this.isStopping = false;
    }
}
