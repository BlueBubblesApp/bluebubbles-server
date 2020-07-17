// Dependency Imports
import { app, ipcMain, BrowserWindow } from "electron";

// Configuration/Filesytem Imports
import { Queue } from "@server/databases/server/entity/Queue";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS } from "@server/constants";

// Database Imports
import { ServerRepository } from "@server/databases/server";
import { MessageRepository } from "@server/databases/imessage";
import { ContactRepository } from "@server/databases/contacts";
import {
    IncomingMessageListener,
    OutgoingMessageListener,
    MessageUpdateListener,
    GroupChangeListener
} from "@server/databases/imessage/listeners";
import { Message, getMessageResponse } from "@server/databases/imessage/entity/Message";
import { ChangeListener } from "@server/databases/imessage/listeners/changeListener";

// Service Imports
import {
    SocketService,
    FCMService,
    AlertService,
    QueueService,
    CaffeinateService,
    NgrokService
} from "@server/services";
import { EventCache } from "@server/eventCache";

import { ActionHandler } from "./helpers/actions";

/**
 * Create a singleton for the server so that it can be referenced everywhere.
 * Plus, we only want one instance of it running at all times.
 */
let server: BlueBubblesServer = null;
export const ServerSingleton = (win: BrowserWindow = null) => {
    // If we already have a server, update the window (if not null) and return
    // the same instance
    if (server) {
        if (win) server.window = win;
        return server;
    }

    server = new BlueBubblesServer(win);
    return server;
};

/**
 * Main entry point for the back-end server
 * This will handle all services and helpers that get spun
 * up when running the application.
 */
class BlueBubblesServer {
    window: BrowserWindow;

    repo: ServerRepository;

    iMessageRepo: MessageRepository;

    contactsRepo: ContactRepository;

    ngrokServer: string;

    socket: SocketService;

    fcm: FCMService;

    alerter: AlertService;

    queue: QueueService;

    caffeinate: CaffeinateService;

    ngrokService: NgrokService;

    actionHandler: ActionHandler;

    chatListeners: ChangeListener[];

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
        this.repo = null;
        this.iMessageRepo = null;
        this.contactsRepo = null;

        // Other helpers
        this.eventCache = null;
        this.chatListeners = [];
        this.actionHandler = null;

        // Services
        this.socket = null;
        this.fcm = null;
        this.queue = null;
        this.caffeinate = null;

        this.hasDiskAccess = true;
        this.hasAccessibilityAccess = false;
        this.hasSetup = false;
        this.hasStarted = false;
    }

    emitToUI(event: string, data: any) {
        if (this.window) this.window.webContents.send(event, data);
    }

    /**
     * Handler for sending logs. This allows us to also route
     * the logs to the main Electron window
     *
     * @param message The message to print
     * @param type The log type
     */
    log(message: any, type?: "log" | "error" | "dir" | "warn") {
        switch (type) {
            case "error":
                console.error(message);
                AlertService.create("error", message);
                break;
            case "dir":
                console.dir(message);
                break;
            case "warn":
                console.warn(message);
                AlertService.create("warn", message);
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

        this.fcm.start();

        if (!this.hasStarted) {
            this.log("Starting Configuration IPC Listeners..");
            this.startConfigIpcListeners();
        }

        await this.startServices();
    }

    /**
     * Performs the initial setup for the server.
     * Mainly, instantiation of a bunch of classes/handlers
     */
    private async setup(): Promise<void> {
        this.log("Performing initial setup...");
        this.log("Initializing server database...");
        this.repo = new ServerRepository();
        await this.repo.initialize();

        // Setup lightweight message cache
        this.eventCache = new EventCache();

        try {
            this.log("Initializing filesystem...");
            FileSystem.setup();
        } catch (ex) {
            this.log(`Failed to setup Filesystem! ${ex.message}`, "error");
        }

        await this.setupCaffeinate();

        try {
            this.log("Initializing connection to Google FCM...");
            this.fcm = new FCMService();
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
     * Sets up the caffeinate service
     */
    private async setupCaffeinate(): Promise<void> {
        try {
            this.caffeinate = new CaffeinateService();
            if (this.repo.getConfig("auto_caffeinate")) {
                this.caffeinate.start();
            }
        } catch (ex) {
            this.log(`Failed to setup caffeinate service! ${ex.message}`, "error");
        }
    }

    /**
     * Emits a notification to to your connected devices over FCM
     *
     * @param type The type of notification
     * @param data Associated data with the notification (as a string)
     */
    async sendNotification(type: string, data: any) {
        this.socket.server.emit(type, data);

        // Send notification to devices
        if (this.fcm.app) {
            const devices = await this.repo.devices().find();
            if (!devices || devices.length === 0) return;

            const notifData = JSON.stringify(data);
            await this.fcm.sendNotification(
                devices.map(device => device.identifier),
                { type, data: notifData }
            );
        }
    }

    /**
     * Starts the chat listener service. This service will listen for new
     * iMessages from your chat database. Anytime there is a new message,
     * we will emit a message to the socket, as well as the FCM server
     */
    private startChatListener() {
        if (!this.iMessageRepo?.db) {
            AlertService.create(
                "info",
                "Restart the app once 'Full Disk Access' and 'Accessibility' permissions are enabled"
            );
            return;
        }

        // Start the queue service
        this.queue.start();
        this.queue.on("message-timeout", async (item: Queue) => {
            const text = item.text.startsWith(item.tempGuid) ? "image" : `text, [${item.text}]`;
            this.log(`Message send timeout for ${text}`, "warn");
            await this.sendNotification("message-timeout", item);
        });
        this.queue.on("message-match", async (item: { tempGuid: string; message: Message }) => {
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
            // eslint-disable-next-line no-return-await
            return await this.repo.devices().find();
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
                if (this.repo.hasConfig(item) && this.repo.getConfig(item) !== args[item]) {
                    this.repo.setConfig(item, args[item]);

                    // If the socket port changed, disconnect and reconnect
                    if (item === "socket_port") {
                        await this.ngrokService.restart();
                        await this.socket.restart();
                    }
                }
            }

            this.emitToUI("config-update", this.repo.config);
            return this.repo.config;
        });

        ipcMain.handle("get-config", async (_, __) => {
            if (!this.repo.db) return {};
            return this.repo.config;
        });

        ipcMain.handle("get-alerts", async (_, __) => {
            const alerts = await AlertService.find();
            return alerts;
        });

        ipcMain.handle("mark-alert-as-read", async (_, args) => {
            const alertIds = args ?? [];
            for (const id of alertIds) {
                await AlertService.markAsRead(id);
            }
        });

        ipcMain.handle("set-fcm-server", (_, args) => {
            FileSystem.saveFCMServer(args);
            this.fcm.start();
        });

        ipcMain.handle("set-fcm-client", (_, args) => {
            FileSystem.saveFCMClient(args);
        });

        ipcMain.handle("toggle-tutorial", async (_, toggle) => {
            await this.repo.setConfig("tutorial_is_done", toggle);

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
            if (this.caffeinate && toggle) {
                this.caffeinate.start();
            } else if (this.caffeinate && !toggle) {
                this.caffeinate.stop();
            }

            await this.repo.setConfig("auto_caffeinate", toggle);
        });

        ipcMain.handle("get-caffeinate-status", (_, __) => {
            return {
                isCaffeinated: this.caffeinate.isCaffeinated,
                autoCaffeinate: this.repo.getConfig("auto_caffeinate")
            };
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
            await this.repo.setConfig("auto_start", toggle);
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
            this.socket = new SocketService();
        } catch (ex) {
            this.log(`Failed to setup socket service! ${ex.message}`, "error");
        }

        try {
            this.log("Initializing queue service...");
            this.queue = new QueueService(this.eventCache, DEFAULT_POLL_FREQUENCY_MS);
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

        try {
            this.log("Connecting to Ngrok...");
            this.ngrokService = new NgrokService();
            await this.ngrokService.restart();
        } catch (ex) {
            this.log(`Failed to connect to Ngrok! ${ex.message}`, "error");
        }

        this.log("Starting socket service...");
        this.socket.restart();

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
        this.queue.removeAllListeners();
        for (const i of this.chatListeners) i.stop();
        this.chatListeners = [];

        // Disconnect & reconnect to the iMessage DB
        if (this.iMessageRepo.db.isConnected) {
            await this.iMessageRepo.db.close();
            await this.iMessageRepo.db.connect();
        }

        // Remove the FCM connection (this will reconnect in `start`)
        if (this.fcm.app) await this.fcm.app.delete();

        // Start the server up again
        await this.start();
    }
}
