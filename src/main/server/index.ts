// Dependency Imports
import { app, ipcMain, BrowserWindow } from "electron";
import { createConnection, Connection } from "typeorm";
import * as ngrok from "ngrok";
import * as path from "path";

// Configuration/Filesytem Imports
import { Config } from "@server/entity/Config";
import { Alert } from "@server/entity/Alert";
import { Device } from "@server/entity/Device";
import { Queue } from "@server/entity/Queue";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS, DEFAULT_DB_ITEMS } from "@server/constants";

// Database Imports
import { MessageRepository } from "@server/api/imessage";
import { ContactRepository } from "@server/api/contacts";
import {
    IncomingMessageListener,
    OutgoingMessageListener,
    MessageUpdateListener,
    GroupChangeListener
} from "@server/api/imessage/listeners";
import { Message, getMessageResponse } from "@server/api/imessage/entity/Message";

// Service Imports
import { SocketService, FCMService, AlertService, QueueService, CaffeinateService } from "@server/services";
import { EventCache } from "@server/eventCache";
import { boolToString, toBoolean } from "./helpers/utils";
import { ChangeListener } from "./api/imessage/listeners/changeListener";

/**
 * Main entry point for the back-end server
 * This will handle all services and helpers that get spun
 * up when running the application.
 */
export class BlueBubblesServer {
    window: BrowserWindow;

    db: Connection;

    iMessageRepo: MessageRepository;

    contactsRepo: ContactRepository;

    ngrokServer: string;

    socketService: SocketService;

    fcmService: FCMService;

    alertService: AlertService;

    queueService: QueueService;

    caffeinateService: CaffeinateService;

    chatListeners: ChangeListener[];

    config: { [key: string]: any };

    eventCache: EventCache;

    hasDiskAccess: boolean;

    hasAccessibilityAccess: boolean;

    hasSetup: boolean;

    hasStarted: boolean;

    /**
     * Constructor to just initialize everything to null pretty much
     *
     * @param window The browser window associated with the Electron app
     */
    constructor(window: BrowserWindow) {
        this.window = window;

        // Databases
        this.db = null;
        this.iMessageRepo = null;
        this.contactsRepo = null;

        // Other helpers
        this.ngrokServer = null;
        this.config = {};
        this.eventCache = null;

        // Services
        this.socketService = null;
        this.alertService = null;
        this.fcmService = null;
        this.queueService = null;
        this.caffeinateService = null;
        this.chatListeners = [];

        this.hasDiskAccess = true;
        this.hasAccessibilityAccess = false;
        this.hasSetup = false;
        this.hasStarted = false;
    }

    private emitToUI(event: string, data: any) {
        if (this.window) this.window.webContents.send(event, data);
    }

    /**
     * Handler for sending logs. This allows us to also route
     * the logs to the main Electron window
     *
     * @param message The message to print
     * @param type The log type
     */
    private log(message: any, type?: "log" | "error" | "dir" | "warn") {
        switch (type) {
            case "error":
                console.error(message);
                this.alertService.create("error", message);
                break;
            case "dir":
                console.dir(message);
                break;
            case "warn":
                console.warn(message);
                this.alertService.create("warn", message);
                break;
            case "log":
            default:
                console.log(message);
        }

        this.emitToUI("new-log", message);
    }

    /**
     * Officially starts the server. First, runs the setup,
     * then starts all of the services required for the server
     */
    async start(): Promise<void> {
        await this.setup();

        this.fcmService.start();

        if (!this.hasStarted) {
            this.log("Starting Configuration IPC Listeners..");
            this.startConfigIpcListeners();
        }

        await this.startServices();
    }

    /**
     * Sets a config value in the database and class
     *
     * @param name Name of the config item
     * @param value Value of the config item
     */
    private async setConfig(name: string, value: any): Promise<void> {
        await this.db.getRepository(Config).update({ name }, { value });
        if (typeof value === "boolean") {
            this.config[name] = boolToString(value as boolean);
        } else {
            this.config[name] = String(value);
        }

        this.emitToUI("config-update", this.config);
    }

    /**
     * Performs the initial setup for the server.
     * Mainly, instantiation of a bunch of classes/handlers
     */
    private async setup(): Promise<void> {
        this.log("Performing initial setup...");
        await this.initializeDatabase();
        await this.setupDefaults();

        // Setup lightweight message cache
        this.eventCache = new EventCache();

        this.log("Initializing alert service...");
        this.alertService = new AlertService(this.db, this.window);

        try {
            this.log("Initializing filesystem...");
            FileSystem.setup();
        } catch (ex) {
            this.log(`Failed to setup Filesystem! ${ex.message}`, "error");
        }

        this.log("Initializing configuration database...");
        const cfg = await this.db.getRepository(Config).find();
        cfg.forEach(item => {
            this.config[item.name] = item.value;
        });

        await this.setupCaffeinate();

        try {
            this.log("Initializing connection to Google FCM...");
            this.fcmService = new FCMService();
        } catch (ex) {
            this.log(`Failed to setup Google FCM service! ${ex.message}`, "error");
        }

        // Also check accessibility permissions
        this.log("Bypassing permissions temporarily..");
        // this.log("Checking Permissions..");
        // const fdPerms: string = permissions.getAuthStatus("full-disk-access");
        // const abPerms: string = permissions.getAuthStatus("accessibility");
        //
        // // Only return out if we don't have disk access
        // this.hasAccessibilityAccess = abPerms === "authorized";
        // if (!this.hasAccessibilityAccess)
        //     this.log("Accessibility permissions are required for certain actions!", "error");
        // this.hasDiskAccess = fdPerms === "authorized";
        // if (!this.hasDiskAccess) {
        //     this.log("Full Disk Access permissions are required!", "error");
        //     return;
        // }

        try {
            this.log("Launching Services..");
            await this.setupServices();
        } catch (ex) {
            this.log("There was a problem launching the Server listeners.", "error");
        }
    }

    /**
     * Initializes the connection to the configuration database
     */
    private async initializeDatabase(): Promise<void> {
        if (this.db) return;

        try {
            this.db = await createConnection({
                type: "sqlite",
                database: path.join(FileSystem.baseDir, "config.db"),
                entities: [Config, Device, Alert, Queue],
                synchronize: true,
                logging: false
            });
        } catch (ex) {
            this.log(`Failed to connect to configuration database! ${ex.message}`, "error");
        }
    }

    /**
     * This sets any default database values, if the database
     * has not already been initialized
     */
    private async setupDefaults(): Promise<void> {
        try {
            const repo = this.db.getRepository(Config);
            for (const key of Object.keys(DEFAULT_DB_ITEMS)) {
                const item = await repo.findOne({ name: key });
                if (!item) await this.addConfigItem(key, DEFAULT_DB_ITEMS[key]());
            }
        } catch (ex) {
            this.log(`Failed to setup default configurations! ${ex.message}`, "error");
        }
    }

    /**
     * Sets up the caffeinate service
     */
    private async setupCaffeinate(): Promise<void> {
        try {
            this.caffeinateService = new CaffeinateService();
            if (this.config.auto_caffeinate === "1") {
                this.caffeinateService.start();
            }
        } catch (ex) {
            this.log(`Failed to setup caffeinate service! ${ex.message}`, "error");
        }
    }

    /**
     * Sets up a connection to the Ngrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connectToNgrok(): Promise<void> {
        try {
            this.ngrokServer = await ngrok.connect({
                port: this.config.socket_port,
                // This is required to run ngrok in production
                binPath: bPath => bPath.replace("app.asar", "app.asar.unpacked")
            });

            await this.setConfig("server_address", this.ngrokServer);

            // Emit this over the socket
            if (this.socketService) this.socketService.server.emit("new-server", this.ngrokServer);

            if (this.socketService) await this.sendNotification("new-server", this.ngrokServer);
            await this.fcmService.setServerUrl(this.ngrokServer);
        } catch (ex) {
            this.log(`Failed to connect to ngrok! ${ex.message}`, "error");
        }
    }

    /**
     * Emits a notification to to your connected devices over FCM
     *
     * @param type The type of notification
     * @param data Associated data with the notification (as a string)
     */
    async sendNotification(type: string, data: any) {
        this.socketService.server.emit(type, data);

        // Send notification to devices
        if (this.fcmService.app) {
            const devices = await this.db.getRepository(Device).find();
            if (!devices || devices.length === 0) return;

            const notifData = JSON.stringify(data);
            await this.fcmService.sendNotification(
                devices.map(device => device.identifier),
                { type, data: notifData }
            );
        }
    }

    /**
     * Helper method for addind a new configuration item to the
     * database.
     *
     * @param name The name of the config item
     * @param value The initial value of the config item
     */
    private async addConfigItem(name: string, value: string | number): Promise<Config> {
        const item = new Config();
        item.name = name;
        item.value = String(value);
        await this.db.getRepository(Config).save(item);
        return item;
    }

    /**
     * Starts the chat listener service. This service will listen for new
     * iMessages from your chat database. Anytime there is a new message,
     * we will emit a message to the socket, as well as the FCM server
     */
    private startChatListener() {
        if (!this.iMessageRepo?.db) {
            this.alertService.create(
                "info",
                "Restart the app once 'Full Disk Access' and 'Accessibility' permissions are enabled"
            );
            return;
        }

        // Start the queue service
        this.queueService.start();
        this.queueService.on("message-timeout", async (item: Queue) => {
            const text = item.text.startsWith(item.tempGuid) ? "image" : `text, [${item.text}]`;
            this.log(`Message send timeout for ${text}`, "warn");
            await this.sendNotification("message-timeout", item);
        });
        this.queueService.on("message-match", async (item: { tempGuid: string; message: Message }) => {
            const text = item.message.cacheHasAttachments
                ? `Image: ${item.message.text.slice(1, item.message.text.length) || "<No Text>"}`
                : item.message.text;

            this.log(`Message match found for text, [${text}]`);
            const resp = await getMessageResponse(item.message);
            resp.tempGuid = item.tempGuid;

            // We are emitting this as a new message, the only difference being the included tempGuid
            await this.sendNotification("new-message", resp);
        });

        // Create a listener to listen for new/updated messages
        const newMsgListener = new IncomingMessageListener(
            this.iMessageRepo,
            this.eventCache,
            DEFAULT_POLL_FREQUENCY_MS
        );
        const myMsgListener = new OutgoingMessageListener(
            this.iMessageRepo,
            this.eventCache,
            DEFAULT_POLL_FREQUENCY_MS * 2
        );
        const updatedMsgListener = new MessageUpdateListener(this.iMessageRepo, DEFAULT_POLL_FREQUENCY_MS);

        // No real rhyme or reason to multiply this by 2. It's just not as much a priority
        const groupChangeListener = new GroupChangeListener(this.iMessageRepo, DEFAULT_POLL_FREQUENCY_MS * 2);

        // Add to listeners
        this.chatListeners = [newMsgListener, myMsgListener, updatedMsgListener, groupChangeListener];

        /**
         * Message listener for my messages only. We need this because messages from ourselves
         * need to be fully sent before forwarding to any clients. If we emit a notification
         * before the message is sent, it will cause a duplicate.
         */
        myMsgListener.on("new-entry", async (item: Message) => {
            const text = item.cacheHasAttachments
                ? `Attachment: ${item.text.slice(1, item.text.length) || "<No Text>"}`
                : item.text;
            this.log(`New message from [You]: [${text.substring(0, 50)}]`);

            // Emit it to the socket and FCM devices
            await this.sendNotification("new-message", await getMessageResponse(item));
        });

        /**
         * Message listener for messages that have errored out
         */
        myMsgListener.on("message-send-error", async (item: Message) => {
            const text = item.cacheHasAttachments
                ? `Attachment: ${item.text.slice(1, item.text.length) || "<No Text>"}`
                : item.text;
            this.log(`Failed to send message: [${text.substring(0, 50)}]`);

            // Emit it to the socket and FCM devices

            /**
             * ERROR CODES:
             * 4: Message Timeout
             */
            await this.sendNotification("message-send-error", await getMessageResponse(item));
        });

        /**
         * Message listener for new messages not from yourself. See 'myMsgListener' comment
         * for why we separate them out into two separate listeners.
         */
        newMsgListener.on("new-entry", async (item: Message) => {
            const text = item.cacheHasAttachments
                ? `Attachment: ${item.text.slice(1, item.text.length) || "<No Text>"}`
                : item.text;
            this.log(`New message from [${item.handle?.id}]: [${text.substring(0, 50)}]`);

            // Emit it to the socket and FCM devices
            await this.sendNotification("new-message", await getMessageResponse(item));
        });

        /**
         * Message listener checking for updated messages. This means either the message's
         * delivered date or read date have changed since the last time we checked the database.
         */
        updatedMsgListener.on("updated-entry", async (item: Message) => {
            // ATTENTION: If "from" is null, it means you sent the message from a group chat
            // Check the isFromMe key prior to checking the "from" key
            const from = item.isFromMe ? "You" : item.handle?.id;
            const time = item.dateDelivered || item.dateRead;
            const text = item.dateRead ? "Text Read" : "Text Delivered";
            this.log(`Updated message from [${from}]: [${text} -> ${time.toLocaleString()}]`);

            // Emit it to the socket and FCM devices
            await this.sendNotification("updated-message", await getMessageResponse(item));
        });

        groupChangeListener.on("name-change", async (item: Message) => {
            this.log(`Group name for [${item.cacheRoomnames}] changed to [${item.groupTitle}]`);
            await this.sendNotification("group-name-change", await getMessageResponse(item));
        });

        groupChangeListener.on("participant-removed", async (item: Message) => {
            const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
            this.log(`[${from}] removed [${item.otherHandle}] from [${item.cacheRoomnames}]`);
            await this.sendNotification("participant-removed", await getMessageResponse(item));
        });

        groupChangeListener.on("participant-added", async (item: Message) => {
            const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
            this.log(`[${from}] added [${item.otherHandle}] to [${item.cacheRoomnames}]`);
            await this.sendNotification("participant-added", await getMessageResponse(item));
        });

        groupChangeListener.on("participant-left", async (item: Message) => {
            const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
            this.log(`[${from}] left [${item.cacheRoomnames}]`);
            await this.sendNotification("participant-left", await getMessageResponse(item));
        });
    }

    /**
     * Starts the inter-process-communication handlers. Basically, a router
     * for all requests sent by the Electron front-end
     */
    private startIpcListener() {
        ipcMain.handle("get-message-count", async (event, args) => {
            if (!this.iMessageRepo?.db) return 0;
            const count = await this.iMessageRepo.getMessageCount(args?.after, args?.before, args?.isFromMe);
            return count;
        });

        ipcMain.handle("get-chat-image-count", async (event, args) => {
            if (!this.iMessageRepo?.db) return 0;
            const count = await this.iMessageRepo.getChatImageCounts();
            return count;
        });

        ipcMain.handle("get-group-message-counts", async (event, args) => {
            if (!this.iMessageRepo?.db) return 0;
            const count = await this.iMessageRepo.getChatMessageCounts("group");
            return count;
        });

        ipcMain.handle("get-individual-message-counts", async (event, args) => {
            if (!this.iMessageRepo?.db) return 0;
            const count = await this.iMessageRepo.getChatMessageCounts("individual");
            return count;
        });

        ipcMain.handle("get-devices", async (event, args) => {
            const devices = await this.db.getRepository(Device).find();
            return devices;
        });

        ipcMain.handle("get-fcm-server", (event, args) => {
            return FileSystem.getFCMServer();
        });

        ipcMain.handle("get-fcm-client", (event, args) => {
            return FileSystem.getFCMClient();
        });
    }

    /**
     * Starts configuration related inter-process-communication handlers.
     */
    private startConfigIpcListeners() {
        ipcMain.handle("set-config", async (_, args) => {
            for (const item of Object.keys(args)) {
                if (this.config[item] && this.config[item] !== args[item]) {
                    this.config[item] = args[item];

                    // If the socket port changed, disconnect and reconnect
                    if (item === "socket_port") {
                        await ngrok.disconnect();
                        await this.connectToNgrok();
                        await this.socketService.restart(args[item]);
                    }
                }

                // Update in class
                if (this.config[item]) await this.setConfig(item, args[item]);
            }

            this.emitToUI("config-update", this.config);
            return this.config;
        });

        ipcMain.handle("get-config", async (_, __) => {
            if (!this.db) return {};

            const cfg = await this.db.getRepository(Config).find();
            for (const i of cfg) {
                this.config[i.name] = i.value;
            }

            return this.config;
        });

        ipcMain.handle("get-alerts", async (_, __) => {
            const alerts = await this.alertService.find();
            return alerts;
        });

        ipcMain.handle("mark-alert-as-read", async (_, args) => {
            const alertIds = args ?? [];
            for (const id of alertIds) {
                await this.alertService.markAsRead(id);
            }
        });

        ipcMain.handle("set-fcm-server", (_, args) => {
            FileSystem.saveFCMServer(args);
            this.fcmService.start();
        });

        ipcMain.handle("set-fcm-client", (_, args) => {
            FileSystem.saveFCMClient(args);
        });

        ipcMain.handle("toggle-tutorial", async (_, toggle) => {
            await this.setConfig("tutorial_is_done", boolToString(toggle));

            if (toggle) {
                await this.setupServices();
                await this.startServices();
            }
        });

        ipcMain.handle("open_perms_prompt", async (_, __) => {
            // permissions.askForFullDiskAccess();
        });

        ipcMain.handle("prompt_accessibility_perms", async (_, __) => {
            // permissions.askForAccessibilityAccess();
        });

        ipcMain.handle("check_perms", async (_, __) => {
            return { abPerms: "authorized", fdPerms: "authorized" };
            // return {
            //     abPerms: permissions.getAuthStatus("accessibility"),
            //     fdPerms: permissions.getAuthStatus("full-disk-access")
            // };
        });

        ipcMain.handle("toggle-caffeinate", async (_, toggle) => {
            if (this.caffeinateService && toggle) {
                this.caffeinateService.start();
            } else if (this.caffeinateService && !toggle) {
                this.caffeinateService.stop();
            }

            await this.setConfig("auto_caffeinate", toggle);
        });

        ipcMain.handle("get-caffeinate-status", (_, __) => {
            const autoCaffeinate = toBoolean(this.config.auto_caffeinate);
            return { isCaffeinated: this.caffeinateService.isCaffeinated, autoCaffeinate };
        });

        ipcMain.handle("purge-event-cache", (_, __) => {
            if (this.eventCache.size() === 0) {
                this.log("No events to purge from event cache!");
            } else {
                this.log(`Purging ${this.eventCache.size()} items from the event cache!`);
                this.eventCache.purge();
            }
        });

        ipcMain.handle("toggle-auto-start", async (_, toggle) => {
            await this.setConfig("auto_start", toggle);
            app.setLoginItemSettings({ openAtLogin: toggle, openAsHidden: true });
        });

        ipcMain.handle("restart-server", async (_, __) => {
            await this.restart();
        });
    }

    /**
     * Helper method for running setup on the message services
     */
    private async setupServices() {
        if (this.hasSetup) return;

        try {
            this.log("Connecting to iMessage database...");
            this.iMessageRepo = new MessageRepository();
            await this.iMessageRepo.initialize();
        } catch (ex) {
            this.log(`Failed to connect to iMessage database! Please enable Full Disk Access!`, "error");
        }

        try {
            this.log("Connecting to Contacts database...");
            this.contactsRepo = new ContactRepository();
            await this.contactsRepo.initialize();
        } catch (ex) {
            this.log(`Failed to connect to Contacts database! Please enable Full Disk Access!`, "error");
        }

        try {
            this.log("Initializing up sockets...");
            this.socketService = new SocketService(
                this.db,
                this.iMessageRepo,
                this.contactsRepo,
                this.config.socket_port
            );
        } catch (ex) {
            this.log(`Failed to setup socket service! ${ex.message}`, "error");
        }

        try {
            this.log("Initializing queue service...");
            this.queueService = new QueueService(
                this.db,
                this.iMessageRepo,
                this.eventCache,
                DEFAULT_POLL_FREQUENCY_MS
            );
        } catch (ex) {
            this.log(`Failed to setup queue service! ${ex.message}`, "error");
        }

        this.hasSetup = true;
    }

    /**
     * Helper method for starting the message services
     *
     */
    private async startServices() {
        // Start the IPC listener first for the UI
        if (this.hasDiskAccess && !this.hasStarted) this.startIpcListener();

        // Disconnect from ngrok in case we are connected
        await ngrok.disconnect();

        this.log("Connecting to Ngrok...");
        await this.connectToNgrok();

        this.log("Starting socket service...");
        this.socketService.restart(this.config.socket_port);

        if (this.hasDiskAccess && this.chatListeners.length === 0) {
            this.log("Starting chat listener...");
            this.startChatListener();
        }

        this.hasStarted = true;
    }

    /**
     * Restarts the server
     */
    async restart() {
        this.log("Restarting the server...");

        // Remove all listeners
        this.queueService.removeAllListeners();
        for (const i of this.chatListeners) i.stop();
        this.chatListeners = [];

        // Disconnect & reconnect to the iMessage DB
        if (this.iMessageRepo.db.isConnected) {
            await this.iMessageRepo.db.close();
            await this.iMessageRepo.db.connect();
        }

        // Remove the FCM connection (this will reconnect in `start`)
        if (this.fcmService.app) await this.fcmService.app.delete();

        // Start the server up again
        await this.start();
    }
}
