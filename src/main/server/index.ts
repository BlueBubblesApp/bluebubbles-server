/* eslint-disable class-methods-use-this */
// Dependency Imports
import { app, BrowserWindow, nativeTheme, systemPreferences, dialog } from "electron";
import ServerLog from "electron-log";
import * as process from "process";
import { EventEmitter } from "events";

// Configuration/Filesytem Imports
import { Queue } from "@server/databases/server/entity/Queue";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS } from "@server/constants";

// Database Imports
import { ServerRepository, ServerConfigChange } from "@server/databases/server";
import { MessageRepository } from "@server/databases/imessage";
import { ContactRepository } from "@server/databases/contacts";
import {
    IncomingMessageListener,
    OutgoingMessageListener,
    GroupChangeListener
} from "@server/databases/imessage/listeners";
import { Message, getMessageResponse } from "@server/databases/imessage/entity/Message";
import { ChangeListener } from "@server/databases/imessage/listeners/changeListener";

// Service Imports
import {
    SocketService,
    FCMService,
    AlertService,
    CaffeinateService,
    NgrokService,
    NetworkService,
    QueueService,
    IPCService
} from "@server/services";
import { EventCache } from "@server/eventCache";
import { runTerminalScript, openSystemPreferences } from "@server/fileSystem/scripts";

import { ActionHandler } from "./helpers/actions";
import { sanitizeStr } from "./helpers/utils";
import { ResponseData } from "./types";
import { BlueBubblesHelperService } from "./services/helperProcess";

const findProcess = require("find-process");

// Set the log format
const logFormat = "[{y}-{m}-{d} {h}:{i}:{s}.{ms}] [{level}] {text}";
ServerLog.transports.console.format = logFormat;
ServerLog.transports.file.format = logFormat;

/**
 * Create a singleton for the server so that it can be referenced everywhere.
 * Plus, we only want one instance of it running at all times.
 */
let server: BlueBubblesServer = null;
export const Server = (win: BrowserWindow = null) => {
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
class BlueBubblesServer extends EventEmitter {
    window: BrowserWindow;

    repo: ServerRepository;

    iMessageRepo: MessageRepository;

    contactsRepo: ContactRepository;

    socket: SocketService;

    blueBubblesServerHelper: BlueBubblesHelperService;

    fcm: FCMService;

    alerter: AlertService;

    networkChecker: NetworkService;

    caffeinate: CaffeinateService;

    queue: QueueService;

    ngrok: NgrokService;

    actionHandler: ActionHandler;

    chatListeners: ChangeListener[];

    eventCache: EventCache;

    hasDiskAccess: boolean;

    hasAccessibilityAccess: boolean;

    hasSetup: boolean;

    hasStarted: boolean;

    notificationCount: number;

    isRestarting: boolean;

    /**
     * Constructor to just initialize everything to null pretty much
     *
     * @param window The browser window associated with the Electron app
     */
    constructor(window: BrowserWindow) {
        super();

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
        this.blueBubblesServerHelper = null;
        this.fcm = null;
        this.caffeinate = null;
        this.networkChecker = null;
        this.queue = null;

        this.hasDiskAccess = true;
        this.hasAccessibilityAccess = false;
        this.hasSetup = false;
        this.hasStarted = false;
        this.notificationCount = 0;
        this.isRestarting = false;
    }

    emitToUI(event: string, data: any) {
        try {
            if (this.window) this.window.webContents.send(event, data);
        } catch {
            /* Ignore errors here */
        }
    }

    /**
     * Handler for sending logs. This allows us to also route
     * the logs to the main Electron window
     *
     * @param message The message to print
     * @param type The log type
     */
    log(message: any, type?: "log" | "error" | "warn" | "debug") {
        switch (type) {
            case "error":
                ServerLog.error(message);
                AlertService.create("error", message);
                this.notificationCount += 1;
                break;
            case "debug":
                ServerLog.debug(message);
                break;
            case "warn":
                ServerLog.warn(message);
                AlertService.create("warn", message);
                this.notificationCount += 1;
                break;
            case "log":
            default:
                ServerLog.log(message);
        }

        if (["error", "warn"].includes(type)) {
            app.setBadgeCount(this.notificationCount);
        }

        this.emitToUI("new-log", {
            message,
            type: type ?? "log"
        });
    }

    /**
     * Officially starts the server. First, runs the setup,
     * then starts all of the services required for the server
     */
    async start(): Promise<void> {
        if (!this.hasStarted) {
            this.getTheme();
            await this.setupServer();

            // Do some pre-flight checks
            await this.preChecks();
            if (this.isRestarting) return;

            this.log("Starting Configuration IPC Listeners..");
            IPCService.startConfigIpcListeners();
        }

        try {
            this.log("Launching Services..");
            await this.setupServices();
        } catch (ex) {
            this.log("There was a problem launching the Server listeners.", "error");
        }

        await this.startServices();
        await this.postChecks();

        this.emit("setup-complete");
    }

    /**
     * Performs the initial setup for the server.
     * Mainly, instantiation of a bunch of classes/handlers
     */
    private async setupServer(): Promise<void> {
        this.log("Performing initial setup...");
        this.log("Initializing server database...");
        this.repo = new ServerRepository();
        this.repo.on("config-update", (args: ServerConfigChange) => this.handleConfigUpdate(args));
        await this.repo.initialize();

        // Load notification count
        try {
            const alerts = (await AlertService.find()).filter(item => !item.isRead);
            this.notificationCount = alerts.length;
        } catch (ex) {
            this.log("Failed to get initial notification count. Skipping.", "warn");
        }

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
            this.log("Initializing queue service...");
            this.queue = new QueueService();
        } catch (ex) {
            this.log(`Failed to setup queue service! ${ex.message}`, "error");
        }

        try {
            this.log("Initializing connection to Google FCM...");
            this.fcm = new FCMService();
        } catch (ex) {
            this.log(`Failed to setup Google FCM service! ${ex.message}`, "error");
        }

        try {
            this.log("Initializing network service...");
            this.networkChecker = new NetworkService();
            this.networkChecker.on("status-change", connected => {
                if (connected) {
                    this.log("Re-connected to network!");
                    this.ngrok.restart();
                } else {
                    this.log("Disconnected from network!");
                }
            });

            this.networkChecker.start();
        } catch (ex) {
            this.log(`Failed to setup network service! ${ex.message}`, "error");
        }
    }

    private async preChecks(): Promise<void> {
        this.log("Running pre-start checks...");

        this.setDockIcon();

        try {
            const restartViaTerminal = Server().repo.getConfig("start_via_terminal") as boolean;
            const parentProc = await findProcess("pid", process.ppid);
            const parentName = parentProc && parentProc.length > 0 ? parentProc[0].name : null;

            // Restart if enabled and the parent process is the app being launched
            if (restartViaTerminal && (!parentProc[0].name || parentName === "launchd")) {
                this.isRestarting = true;
                Server().log("Restarting via terminal after post-check (configured)");
                await this.restartViaTerminal();
            }
        } catch (ex) {
            Server().log(`Failed to restart via terminal!\n${ex}`);
        }

        this.log("Finished pre-start checks...");
    }

    private async postChecks(): Promise<void> {
        this.log("Running post-start checks...");

        // Make sure a password is set
        const password = this.repo.getConfig("password") as string;
        const tutorialFinished = this.repo.getConfig("tutorial_is_done") as boolean;
        if (tutorialFinished && (!password || password.length === 0)) {
            dialog.showMessageBox(this.window, {
                type: "warning",
                buttons: ["OK"],
                title: "BlueBubbles Warning",
                message: "No Password Set!",
                detail:
                    `No password is currently set. BlueBubbles will not function correctly without one. ` +
                    `Please go to the configuration page, fill in a password, and save the configuration.`
            });
        }

        this.setDockIcon();

        this.log("Finished post-start checks...");
    }

    private setDockIcon() {
        if (!this.repo || !this.repo.db) return;

        const hideDockIcon = this.repo.getConfig("hide_dock_icon") as boolean;
        if (hideDockIcon) {
            app.dock.hide();
            app.show();
        } else {
            app.dock.show();
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
     * Handles a configuration change
     *
     * @param prevConfig The previous configuration
     * @param nextConfig The current configuration
     */
    private async handleConfigUpdate({ prevConfig, nextConfig }: ServerConfigChange) {
        // If the socket port changed, disconnect and reconnect
        let ngrokRestarted = false;
        if (prevConfig.socket_port !== nextConfig.socket_port) {
            if (this.ngrok) await this.ngrok.restart();
            if (this.socket) await this.socket.restart();
            ngrokRestarted = true;
        }

        // If the ngrok URL is different, emit the change to the listeners
        if (prevConfig.server_address !== nextConfig.server_address) {
            if (this.socket) await this.emitMessage("new-server", nextConfig.server_address, "high");
            if (this.fcm) await this.fcm.setServerUrl(nextConfig.server_address as string);
        }

        // If the ngrok API key is different, restart the ngrok process
        if (prevConfig.ngrok_key !== nextConfig.ngrok_key && !ngrokRestarted) {
            if (this.ngrok) await this.ngrok.restart();
        }

        // If the dock style changes
        if (prevConfig.hide_dock_icon !== nextConfig.hide_dock_icon) {
            this.setDockIcon();
        }

        this.emitToUI("config-update", nextConfig);
    }

    /**
     * Emits a notification to to your connected devices over FCM and socket
     *
     * @param type The type of notification
     * @param data Associated data with the notification (as a string)
     */
    async emitMessage(type: string, data: any, priority: "normal" | "high" = "normal") {
        this.socket.server.emit(type, data);

        // Send notification to devices
        if (FCMService.getApp()) {
            const devices = await this.repo.devices().find();
            if (!devices || devices.length === 0) return;

            const notifData = JSON.stringify(data);
            await this.fcm.sendNotification(
                devices.map(device => device.identifier),
                { type, data: notifData },
                priority
            );
        }
    }

    private getTheme() {
        nativeTheme.on("updated", () => {
            this.setTheme(nativeTheme.shouldUseDarkColors);
        });
    }

    private setTheme(shouldUseDarkColors: boolean) {
        if (shouldUseDarkColors === true) {
            this.emitToUI("theme-update", "dark");
        } else {
            this.emitToUI("theme-update", "light");
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

        // Create a listener to listen for new/updated messages
        const incomingMsgListener = new IncomingMessageListener(
            this.iMessageRepo,
            this.eventCache,
            DEFAULT_POLL_FREQUENCY_MS
        );
        const outgoingMsgListener = new OutgoingMessageListener(
            this.iMessageRepo,
            this.eventCache,
            DEFAULT_POLL_FREQUENCY_MS * 2
        );

        // No real rhyme or reason to multiply this by 2. It's just not as much a priority
        const groupEventListener = new GroupChangeListener(this.iMessageRepo, DEFAULT_POLL_FREQUENCY_MS * 2);

        // Add to listeners
        this.chatListeners = [outgoingMsgListener, incomingMsgListener, groupEventListener];

        /**
         * Message listener for when we find matches for a given sent message
         */
        outgoingMsgListener.on("message-match", async (item: { tempGuid: string; message: Message }) => {
            const text = item.message.cacheHasAttachments
                ? `Attachment: ${sanitizeStr(item.message.text) || "<No Text>"}`
                : item.message.text;

            this.log(`Message match found for text, [${text}]`);
            const resp = await getMessageResponse(item.message);
            resp.tempGuid = item.tempGuid;

            // We are emitting this as a new message, the only difference being the included tempGuid
            await this.emitMessage("new-message", resp);
        });

        /**
         * Message listener for my messages only. We need this because messages from ourselves
         * need to be fully sent before forwarding to any clients. If we emit a notification
         * before the message is sent, it will cause a duplicate.
         */
        outgoingMsgListener.on("new-entry", async (item: Message) => {
            const text = item.cacheHasAttachments ? `Attachment: ${sanitizeStr(item.text) || "<No Text>"}` : item.text;
            this.log(`New message from [You]: [${(text ?? "<No Text>").substring(0, 50)}]`);

            // Emit it to the socket and FCM devices
            await this.emitMessage("new-message", await getMessageResponse(item));
        });

        /**
         * Message listener checking for updated messages. This means either the message's
         * delivered date or read date have changed since the last time we checked the database.
         */
        outgoingMsgListener.on("updated-entry", async (item: Message) => {
            // ATTENTION: If "from" is null, it means you sent the message from a group chat
            // Check the isFromMe key prior to checking the "from" key
            const from = item.isFromMe ? "You" : item.handle?.id;
            const time = item.dateDelivered || item.dateRead;
            const updateType = item.dateRead ? "Text Read" : "Text Delivered";
            const text = item.cacheHasAttachments ? `Attachment: ${sanitizeStr(item.text) || "<No Text>"}` : item.text;
            this.log(
                `Updated message from [${from}]: [${(text ?? "<No Text>").substring(
                    0,
                    50
                )}] - [${updateType} -> ${time.toLocaleString()}]`
            );

            // Emit it to the socket and FCM devices
            await this.emitMessage("updated-message", await getMessageResponse(item));
        });

        /**
         * Message listener for outgoing messages that timedout
         */
        outgoingMsgListener.on("message-timeout", async (item: Queue) => {
            const text = (item.text ?? "").startsWith(item.tempGuid) ? "image" : `text, [${item.text ?? "<No Text>"}]`;
            this.log(`Message send timeout for ${text}`, "warn");
            await this.emitMessage("message-timeout", item);
        });

        /**
         * Message listener for messages that have errored out
         */
        outgoingMsgListener.on("message-send-error", async (item: Message) => {
            const text = item.cacheHasAttachments
                ? `Attachment: ${(item.text ?? " ").slice(1, item.text.length) || "<No Text>"}`
                : item.text;
            this.log(`Failed to send message: [${(text ?? "<No Text>").substring(0, 50)}]`);

            // Emit it to the socket and FCM devices

            /**
             * ERROR CODES:
             * 4: Message Timeout
             */
            await this.emitMessage("message-send-error", await getMessageResponse(item));
        });

        /**
         * Message listener for new messages not from yourself. See 'myMsgListener' comment
         * for why we separate them out into two separate listeners.
         */
        incomingMsgListener.on("new-entry", async (item: Message) => {
            const text = item.cacheHasAttachments
                ? `Attachment: ${(item.text ?? " ").slice(1, item.text.length) || "<No Text>"}`
                : item.text;
            this.log(`New message from [${item.handle?.id}]: [${(text ?? "<No Text>").substring(0, 50)}]`);

            // Emit it to the socket and FCM devices
            await this.emitMessage("new-message", await getMessageResponse(item), "high");
        });

        groupEventListener.on("name-change", async (item: Message) => {
            this.log(`Group name for [${item.cacheRoomnames}] changed to [${item.groupTitle}]`);
            await this.emitMessage("group-name-change", await getMessageResponse(item));
        });

        groupEventListener.on("participant-removed", async (item: Message) => {
            const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
            this.log(`[${from}] removed [${item.otherHandle}] from [${item.cacheRoomnames}]`);
            await this.emitMessage("participant-removed", await getMessageResponse(item));
        });

        groupEventListener.on("participant-added", async (item: Message) => {
            const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
            this.log(`[${from}] added [${item.otherHandle}] to [${item.cacheRoomnames}]`);
            await this.emitMessage("participant-added", await getMessageResponse(item));
        });

        groupEventListener.on("participant-left", async (item: Message) => {
            const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
            this.log(`[${from}] left [${item.cacheRoomnames}]`);
            await this.emitMessage("participant-left", await getMessageResponse(item));
        });

        outgoingMsgListener.on("error", (error: Error) => this.log(error.message, "error"));
        incomingMsgListener.on("error", (error: Error) => this.log(error.message, "error"));
        groupEventListener.on("error", (error: Error) => this.log(error.message, "error"));
    }

    /**
     * Helper method for running setup on the message services
     */
    async setupServices() {
        if (this.hasSetup) return;

        try {
            this.log("Connecting to iMessage database...");
            this.iMessageRepo = new MessageRepository();
            await this.iMessageRepo.initialize();
        } catch (ex) {
            this.log(ex, "error");

            const dialogOpts = {
                type: "error",
                buttons: ["Restart", "Open System Preferences", "Ignore"],
                title: "BlueBubbles Error",
                message: "Full-Disk Access Permission Required!",
                detail:
                    `In order to function correctly, BlueBubbles requires full-disk access. ` +
                    `Please enable Full-Disk Access in System Preferences > Security & Privacy.`
            };

            dialog.showMessageBox(this.window, dialogOpts).then(returnValue => {
                if (returnValue.response === 0) {
                    this.relaunch();
                } else if (returnValue.response === 1) {
                    FileSystem.executeAppleScript(openSystemPreferences());
                    app.quit();
                }
            });
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
            this.log("Initializing up helper service...");
            this.blueBubblesServerHelper = new BlueBubblesHelperService();
        } catch (ex) {
            this.log(`Failed to setup helper service! ${ex.message}`, "error");
        }

        this.log("Checking Permissions...");

        // Log if we dont have accessibility access
        if (systemPreferences.isTrustedAccessibilityClient(false) === true) {
            this.hasAccessibilityAccess = true;
            this.log("Accessibility permissions are enabled");
        } else {
            this.log("Accessibility permissions are required for certain actions!", "error");
        }

        // Log if we dont have accessibility access
        if (this.iMessageRepo?.db) {
            this.hasDiskAccess = true;
            this.log("Full-disk access permissions are enabled");
        } else {
            this.log("Full-disk access permissions are required!", "error");
        }

        this.hasSetup = true;
    }

    /**
     * Helper method for starting the message services
     *
     */
    async startServices() {
        // Start the IPC listener first for the UI
        if (this.hasDiskAccess && !this.hasStarted) IPCService.startIpcListener();

        try {
            this.log("Connecting to Ngrok...");
            this.ngrok = new NgrokService();
            await this.ngrok.restart();
        } catch (ex) {
            this.log(`Failed to connect to Ngrok! ${ex.message}`, "error");
        }

        try {
            this.log("Starting FCM service...");
            await this.fcm.start();
        } catch (ex) {
            this.log(`Failed to start FCM service! ${ex.message}`, "error");
        }

        this.log("Starting socket service...");
        this.socket.restart();

        this.log("Starting helper listener...");
        this.blueBubblesServerHelper.start();

        if (this.hasDiskAccess && this.chatListeners.length === 0) {
            this.log("Starting chat listener...");
            this.startChatListener();
        }

        this.hasStarted = true;
    }

    /**
     * Restarts the server
     */
    async hostRestart() {
        this.log("Restarting the server...");

        // Remove all listeners
        console.log("Removing chat listeners...");
        for (const i of this.chatListeners) i.stop();
        this.chatListeners = [];

        // Disconnect & reconnect to the iMessage DB
        if (this.iMessageRepo.db.isConnected) {
            console.log("Reconnecting to iMessage database...");
            await this.iMessageRepo.db.close();
            await this.iMessageRepo.db.connect();
        }

        // Start the server up again
        await this.start();
    }

    relaunch() {
        this.isRestarting = true;
        app.relaunch({ args: process.argv.slice(1).concat(["--relaunch"]) });
        app.exit(0);
    }

    async stopServices() {
        Server().log("Stopping all services...");

        try {
            await this.ngrok?.stop();
        } catch (ex) {
            Server().log(`There was an issue stopping Ngrok!\n${ex}`);
        }

        try {
            if (this?.socket?.server) this.socket.server.close();
        } catch (ex) {
            Server().log(`There was an issue stopping the socket!\n${ex}`);
        }

        try {
            await this.iMessageRepo?.db?.close();
        } catch (ex) {
            Server().log(`There was an issue stopping the iMessage database connection!\n${ex}`);
        }

        try {
            if (this.repo?.db?.isConnected) {
                await this.repo?.db?.close();
            }
        } catch (ex) {
            Server().log(`There was an issue stopping the server database connection!\n${ex}`);
        }

        try {
            await this.contactsRepo?.db?.close();
        } catch (ex) {
            Server().log(`There was an issue stopping the contacts database connection!\n${ex}`);
        }

        try {
            if (this.networkChecker) this.networkChecker.stop();
        } catch (ex) {
            Server().log(`There was an issue stopping the network checker service!\n${ex}`);
        }

        try {
            FCMService.stop();
        } catch (ex) {
            Server().log(`There was an issue stopping the FCM service!\n${ex}`);
        }

        try {
            if (this.caffeinate) this.caffeinate.stop();
        } catch (ex) {
            Server().log(`There was an issue stopping the caffeinate service!\n${ex}`);
        }
    }

    async restartViaTerminal() {
        // Close everything gracefully
        await this.stopServices();

        // Kick off the restart script
        FileSystem.executeAppleScript(runTerminalScript(process.execPath));

        // Exit the current instance
        app.exit(0);
    }
}
