/* eslint-disable max-len */
/* eslint-disable class-methods-use-this */
// Dependency Imports
import { app, nativeTheme, systemPreferences, dialog } from "electron";
import * as process from "process";
import { EventEmitter } from "events";
import * as macosVersion from "macos-version";

// Logger
import { ServerLoggerFactory, ServerLogger } from "@server/logger/builtins/serverLogger";

// Configuration/Filesytem Imports
import { Queue } from "@server/databases/server/entity/Queue";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS } from "@server/constants";

// Database Imports
import { GlobalConfig } from "@server/databases/globalConfig";
import { ContactRepository } from "@server/databases/contacts";
// import {
//     IncomingMessageListener,
//     OutgoingMessageListener,
//     GroupChangeListener
// } from "@server/databases/imessage/listeners";
// import { Message, getMessageResponse } from "@server/databases/imessage/entity/Message";
// import { ChangeListener } from "@server/databases/imessage/listeners/changeListener";

import { PluginManager } from "@server/plugins";

// Service Imports
// import {
//     SocketService,
//     FCMService,
//     AlertService,
//     CaffeinateService,
//     NgrokService,
//     NetworkService,
//     QueueService,
//     IPCService
// } from "@server/services";
import { EventCache } from "@server/eventCache";
import { runTerminalScript, openSystemPreferences } from "@server/fileSystem/scripts";

import { ActionHandler } from "./helpers/actions";
import { sanitizeStr } from "./helpers/utils";
import { Device } from "./databases/server/entity";
import { ServerDatabase } from "./databases/server";

const findProcess = require("find-process");

const osVersion = macosVersion();

/**
 * Create a singleton for the server so that it can be referenced everywhere.
 * Plus, we only want one instance of it running at all times.
 */
let server: BlueBubblesServer = null;
export const Server = (): BlueBubblesServer => {
    if (server) return server;
    server = new BlueBubblesServer();
    return server;
};

/**
 * Main entry point for the back-end server
 * This will handle all services and helpers that get spun
 * up when running the application.
 */
export class BlueBubblesServer extends EventEmitter {
    private serverDatabase: ServerDatabase;

    get db(): ServerDatabase {
        return this.serverDatabase;
    }

    private globalConfig: GlobalConfig;

    get config(): GlobalConfig {
        return this.globalConfig;
    }

    get appPath(): string {
        const isDev = process.env.NODE_ENV !== "production";
        let appPath = app.getPath("userData");
        if (isDev) {
            appPath = `${app.getPath("userData")}/bluebubbles-server`;
        }

        return appPath;
    }

    private globalLogger: ServerLogger;

    get logger(): ServerLogger {
        return this.globalLogger;
    }

    pluginManager: PluginManager;

    // socket: SocketService;

    // fcm: FCMService;

    // alerter: AlertService;

    // networkChecker: NetworkService;

    // caffeinate: CaffeinateService;

    // queue: QueueService;

    // ngrok: NgrokService;

    actionHandler: ActionHandler;

    // chatListeners: ChangeListener[];

    eventCache: EventCache;

    hasDiskAccess: boolean;

    hasAccessibilityAccess: boolean;

    hasSetup: boolean;

    hasStarted: boolean;

    notificationCount: number;

    isRestarting: boolean;

    isStopping: boolean;

    /**
     * Constructor to just initialize everything to null pretty much
     *
     * @param window The browser window associated with the Electron app
     */
    constructor() {
        super();

        // Databases
        this.globalConfig = null;
        this.globalLogger = null;
        this.serverDatabase = null;

        // Other helpers
        this.eventCache = null;
        // this.chatListeners = [];
        this.actionHandler = null;

        // Plugin Manager
        this.pluginManager = new PluginManager();

        // Services
        // this.socket = null;
        // this.fcm = null;
        // this.caffeinate = null;
        // this.networkChecker = null;
        // this.queue = null;

        this.hasDiskAccess = true;
        this.hasAccessibilityAccess = false;
        this.hasSetup = false;
        this.hasStarted = false;
        this.notificationCount = 0;
        this.isRestarting = false;
        this.isStopping = false;
    }

    emitToUI(event: string, data: any) {
        // try {
        //     if (this.window) this.window.webContents.send(event, data);
        // } catch {
        //     /* Ignore errors here */
        // }
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

            this.logger.log("Starting Configuration IPC Listeners..");
            // IPCService.startConfigIpcListeners();
        }

        try {
            await this.pluginManager.loadPlugins();
            await this.pluginManager.startPlugins();
        } catch (ex) {
            this.logger.error("There was a problem launching the plugins.");
            this.logger.error(ex);
        }

        try {
            this.logger.info("Launching Services..");
            await this.setupServices();
        } catch (ex) {
            this.logger.error("There was a problem launching the Server listeners.");
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
        // Instantiate the global logger (server) so others can use it too
        this.globalLogger = ServerLoggerFactory(this);
        this.logger.info("Performing initial setup...");

        // Instantiate the global database
        this.logger.info("Initializing global config database...");
        this.globalConfig = new GlobalConfig();
        // this.globalConfig.on("config-update", (args: IConfigChange) => this.handleConfigUpdate(args));
        await this.globalConfig.initialize();

        // Init the rest of the server DB
        this.logger.info("Initializing server database...");
        this.serverDatabase = new ServerDatabase();
        await this.serverDatabase.initialize();

        // Setup lightweight message cache
        this.logger.info("Initializing event cache...");
        this.eventCache = new EventCache();

        try {
            this.logger.info("Initializing filesystem...");
            FileSystem.setup();
        } catch (ex) {
            this.logger.error(`Failed to setup Filesystem! ${ex.message}`);
        }

        // try {
        //     this.logger.info("Initializing queue service...");
        //     this.queue = new QueueService();
        // } catch (ex) {
        //     this.logger.error(`Failed to setup queue service! ${ex.message}`);
        // }

        // try {
        //     this.logger.info("Initializing connection to Google FCM...");
        //     this.fcm = new FCMService();
        // } catch (ex) {
        //     this.logger.error(`Failed to setup Google FCM service! ${ex.message}`);
        // }

        // try {
        //     this.logger.info("Initializing network service...");
        //     this.networkChecker = new NetworkService();
        //     this.networkChecker.on("status-change", (connected: any) => {
        //         if (connected) {
        //             this.logger.info("Re-connected to network!");
        //             this.ngrok.restart();
        //         } else {
        //             this.logger.info("Disconnected from network!");
        //         }
        //     });

        //     this.networkChecker.start();
        // } catch (ex) {
        //     this.logger.error(`Failed to setup network service! ${ex.message}`);
        // }
    }

    private async preChecks(): Promise<void> {
        this.logger.info("Running pre-start checks...");

        // Set the dock icon according to the config
        this.setDockIcon();

        try {
            // Restart via terminal if configured
            const restartViaTerminal = Server().globalConfig.get("start_via_terminal") as boolean;
            const parentProc = await findProcess("pid", process.ppid);
            const parentName = parentProc && parentProc.length > 0 ? parentProc[0].name : null;

            // Restart if enabled and the parent process is the app being launched
            if (restartViaTerminal && (!parentProc[0].name || parentName === "launchd")) {
                this.isRestarting = true;
                this.logger.info("Restarting via terminal after post-check (configured)");
                await this.restartViaTerminal();
            }
        } catch (ex) {
            this.logger.error(`Failed to restart via terminal!\n${ex}`);
        }

        // Log some server metadata
        this.logger.debug(`Server Metadata -> macOS Version: v${osVersion}`);
        this.logger.debug(`Server Metadata -> Local Timezone: ${Intl.DateTimeFormat().resolvedOptions().timeZone}`);

        // Check if on Big Sur. If we are, then create a log/alert saying that
        const isBigSur = macosVersion.isGreaterThanOrEqualTo("11.0");
        if (isBigSur) {
            this.logger.warn("Warning: macOS Big Sur does NOT support creating chats due to API limitations!");
        }

        this.logger.info("Finished pre-start checks...");
    }

    private async postChecks(): Promise<void> {
        this.setDockIcon();
        this.logger.info("Finished post-start checks...");
    }

    private setDockIcon() {
        if (!this.globalConfig || !this.globalConfig.dbConn) return;

        const hideDockIcon = this.globalConfig.get("hide_dock_icon") as boolean;
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
        // try {
        //     this.caffeinate = new CaffeinateService();
        //     if (this.globalConfig.get("auto_caffeinate")) {
        //         this.caffeinate.start();
        //     }
        // } catch (ex) {
        //     this.logger.error(`Failed to setup caffeinate service! ${ex.message}`);
        // }
    }

    // /**
    //  * Handles a configuration change
    //  *
    //  * @param prevConfig The previous configuration
    //  * @param nextConfig The current configuration
    //  */
    // private async handleConfigUpdate({ prevConfig, nextConfig }: IConfigChange) {
    //     // TODO
    // }

    /**
     * Emits a notification to to your connected devices over FCM and socket
     *
     * @param type The type of notification
     * @param data Associated data with the notification (as a string)
     */
    async emitMessage(type: string, data: any, priority: "normal" | "high" = "normal") {
        // this.socket.server.emit(type, data);
        // // Send notification to devices
        // if (FCMService.getApp()) {
        //     const devices = await this.globalConfig.devices().find();
        //     if (!devices || devices.length === 0) return;
        //     const notifData = JSON.stringify(data);
        //     await this.fcm.sendNotification(
        //         devices.map((device: Device) => device.identifier),
        //         { type, data: notifData },
        //         priority
        //     );
        // }
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
        // if (!this.iMessageRepo?.db) {
        //     AlertService.create(
        //         "info",
        //         "Restart the app once 'Full Disk Access' and 'Accessibility' permissions are enabled"
        //     );
        //     return;
        // }
        // // Create a listener to listen for new/updated messages
        // const incomingMsgListener = new IncomingMessageListener(
        //     this.iMessageRepo,
        //     this.eventCache,
        //     DEFAULT_POLL_FREQUENCY_MS
        // );
        // const outgoingMsgListener = new OutgoingMessageListener(
        //     this.iMessageRepo,
        //     this.eventCache,
        //     DEFAULT_POLL_FREQUENCY_MS * 2
        // );
        // // No real rhyme or reason to multiply this by 2. It's just not as much a priority
        // const groupEventListener = new GroupChangeListener(this.iMessageRepo, DEFAULT_POLL_FREQUENCY_MS * 2);
        // // Add to listeners
        // this.chatListeners = [outgoingMsgListener, incomingMsgListener, groupEventListener];
        // /**
        //  * Message listener for when we find matches for a given sent message
        //  */
        // outgoingMsgListener.on("message-match", async (item: { tempGuid: string; message: Message }) => {
        //     const text = item.message.cacheHasAttachments
        //         ? `Attachment: ${sanitizeStr(item.message.text) || "<No Text>"}`
        //         : item.message.text;
        //     this.logger.info(`Message match found for text, [${text}]`);
        //     const resp = await getMessageResponse(item.message);
        //     resp.tempGuid = item.tempGuid;
        //     // We are emitting this as a new message, the only difference being the included tempGuid
        //     await this.emitMessage("new-message", resp);
        // });
        // /**
        //  * Message listener for my messages only. We need this because messages from ourselves
        //  * need to be fully sent before forwarding to any clients. If we emit a notification
        //  * before the message is sent, it will cause a duplicate.
        //  */
        // outgoingMsgListener.on("new-entry", async (item: Message) => {
        //     const text = item.cacheHasAttachments ? `Attachment: ${sanitizeStr(item.text) || "<No Text>"}` : item.text;
        //     this.logger.info(`New message from [You]: [${(text ?? "<No Text>").substring(0, 50)}]`);
        //     // Emit it to the socket and FCM devices
        //     await this.emitMessage("new-message", await getMessageResponse(item));
        // });
        // /**
        //  * Message listener checking for updated messages. This means either the message's
        //  * delivered date or read date have changed since the last time we checked the database.
        //  */
        // outgoingMsgListener.on("updated-entry", async (item: Message) => {
        //     // ATTENTION: If "from" is null, it means you sent the message from a group chat
        //     // Check the isFromMe key prior to checking the "from" key
        //     const from = item.isFromMe ? "You" : item.handle?.id;
        //     const time = item.dateDelivered || item.dateRead;
        //     const updateType = item.dateRead ? "Text Read" : "Text Delivered";
        //     const text = item.cacheHasAttachments ? `Attachment: ${sanitizeStr(item.text) || "<No Text>"}` : item.text;
        //     this.logger.info(
        //         `Updated message from [${from}]: [${(text ?? "<No Text>").substring(
        //             0,
        //             50
        //         )}] - [${updateType} -> ${time.toLocaleString()}]`
        //     );
        //     // Emit it to the socket and FCM devices
        //     await this.emitMessage("updated-message", await getMessageResponse(item));
        // });
        // /**
        //  * Message listener for outgoing messages that timedout
        //  */
        // outgoingMsgListener.on("message-timeout", async (item: Queue) => {
        //     const text = (item.text ?? "").startsWith(item.tempGuid) ? "image" : `text, [${item.text ?? "<No Text>"}]`;
        //     this.logger.warn(`Message send timeout for ${text}`);
        //     await this.emitMessage("message-timeout", item);
        // });
        // /**
        //  * Message listener for messages that have errored out
        //  */
        // outgoingMsgListener.on("message-send-error", async (item: Message) => {
        //     const text = item.cacheHasAttachments
        //         ? `Attachment: ${(item.text ?? " ").slice(1, item.text.length) || "<No Text>"}`
        //         : item.text;
        //     this.logger.info(`Failed to send message: [${(text ?? "<No Text>").substring(0, 50)}]`);
        //     // Emit it to the socket and FCM devices
        //     /**
        //      * ERROR CODES:
        //      * 4: Message Timeout
        //      */
        //     await this.emitMessage("message-send-error", await getMessageResponse(item));
        // });
        // /**
        //  * Message listener for new messages not from yourself. See 'myMsgListener' comment
        //  * for why we separate them out into two separate listeners.
        //  */
        // incomingMsgListener.on("new-entry", async (item: Message) => {
        //     const text = item.cacheHasAttachments
        //         ? `Attachment: ${(item.text ?? " ").slice(1, item.text.length) || "<No Text>"}`
        //         : item.text;
        //     this.logger.info(`New message from [${item.handle?.id}]: [${(text ?? "<No Text>").substring(0, 50)}]`);
        //     // Emit it to the socket and FCM devices
        //     await this.emitMessage("new-message", await getMessageResponse(item), "high");
        // });
        // groupEventListener.on("name-change", async (item: Message) => {
        //     this.logger.info(`Group name for [${item.cacheRoomnames}] changed to [${item.groupTitle}]`);
        //     await this.emitMessage("group-name-change", await getMessageResponse(item));
        // });
        // groupEventListener.on("participant-removed", async (item: Message) => {
        //     const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
        //     this.logger.info(`[${from}] removed [${item.otherHandle}] from [${item.cacheRoomnames}]`);
        //     await this.emitMessage("participant-removed", await getMessageResponse(item));
        // });
        // groupEventListener.on("participant-added", async (item: Message) => {
        //     const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
        //     this.logger.info(`[${from}] added [${item.otherHandle}] to [${item.cacheRoomnames}]`);
        //     await this.emitMessage("participant-added", await getMessageResponse(item));
        // });
        // groupEventListener.on("participant-left", async (item: Message) => {
        //     const from = item.isFromMe || item.handleId === 0 ? "You" : item.handle?.id;
        //     this.logger.info(`[${from}] left [${item.cacheRoomnames}]`);
        //     await this.emitMessage("participant-left", await getMessageResponse(item));
        // });
        // outgoingMsgListener.on("error", (error: Error) => this.logger.error(error.message));
        // incomingMsgListener.on("error", (error: Error) => this.logger.error(error.message));
        // groupEventListener.on("error", (error: Error) => this.logger.error(error.message));
    }

    /**
     * Helper method for running setup on the message services
     */
    async setupServices() {
        if (this.hasSetup) return;

        // try {
        //     this.logger.info("Connecting to iMessage database...");
        //     this.iMessageRepo = new MessageRepository();
        //     await this.iMessageRepo.initialize();
        // } catch (ex) {
        //     this.logger.error(ex);

        //     const dialogOpts = {
        //         type: "error",
        //         buttons: ["Restart", "Open System Preferences", "Ignore"],
        //         title: "BlueBubbles Error",
        //         message: "Full-Disk Access Permission Required!",
        //         detail:
        //             `In order to function correctly, BlueBubbles requires full-disk access. ` +
        //             `Please enable Full-Disk Access in System Preferences > Security & Privacy.`
        //     };

        //     dialog.showMessageBox(this.window, dialogOpts).then(returnValue => {
        //         if (returnValue.response === 0) {
        //             this.relaunch();
        //         } else if (returnValue.response === 1) {
        //             FileSystem.executeAppleScript(openSystemPreferences());
        //             app.quit();
        //         }
        //     });
        // }

        // try {
        //     this.logger.info("Connecting to Contacts database...");
        //     this.contactsRepo = new ContactRepository();
        //     await this.contactsRepo.initialize();
        // } catch (ex) {
        //     this.logger.error(`Failed to connect to Contacts database! Please enable Full Disk Access!`);
        // }

        // try {
        //     this.logger.info("Initializing up sockets...");
        //     this.socket = new SocketService();
        // } catch (ex) {
        //     this.logger.error(`Failed to setup socket service! ${ex.message}`);
        // }

        this.logger.info("Checking Permissions...");

        // Log if we dont have accessibility access
        if (systemPreferences.isTrustedAccessibilityClient(false) === true) {
            this.hasAccessibilityAccess = true;
            this.logger.info("Accessibility permissions are enabled");
        } else {
            this.logger.error("Accessibility permissions are required for certain actions!");
        }

        // Log if we dont have accessibility access
        // if (this.iMessageRepo?.db) {
        //     this.hasDiskAccess = true;
        //     this.logger.info("Full-disk access permissions are enabled");
        // } else {
        //     this.logger.error("Full-disk access permissions are required!");
        // }

        this.hasSetup = true;
    }

    /**
     * Helper method for starting the message services
     *
     */
    async startServices() {
        // Start the IPC listener first for the UI
        // if (this.hasDiskAccess && !this.hasStarted) IPCService.startIpcListener();

        // try {
        //     this.logger.info("Connecting to Ngrok...");
        //     this.ngrok = new NgrokService();
        //     await this.ngrok.restart();
        // } catch (ex) {
        //     this.logger.error(`Failed to connect to Ngrok! ${ex.message}`);
        // }

        // try {
        //     this.logger.info("Starting FCM service...");
        //     await this.fcm.start();
        // } catch (ex) {
        //     this.logger.error(`Failed to start FCM service! ${ex.message}`);
        // }

        // this.logger.info("Starting socket service...");
        // this.socket.restart();

        // if (this.hasDiskAccess && this.chatListeners.length === 0) {
        //     this.logger.info("Starting chat listener...");
        //     this.startChatListener();
        // }

        this.hasStarted = true;
    }

    /**
     * Restarts the server
     */
    async hostRestart() {
        this.logger.info("Restarting the server...");

        // Remove all listeners
        // console.log("Removing chat listeners...");
        // for (const i of this.chatListeners) i.stop();
        // this.chatListeners = [];

        // // Disconnect & reconnect to the iMessage DB
        // if (this.iMessageRepo.db.isConnected) {
        //     console.log("Reconnecting to iMessage database...");
        //     await this.iMessageRepo.db.close();
        //     await this.iMessageRepo.db.connect();
        // }

        // Start the server up again
        await this.start();
    }

    async relaunch() {
        this.isRestarting = true;

        // Close everything gracefully
        await this.stopServices();

        // Relaunch the process
        app.relaunch({ args: process.argv.slice(1).concat(["--relaunch"]) });
        app.exit(0);
    }

    async stopServices() {
        this.isStopping = true;
        this.logger.info("Stopping all services...");

        // try {
        //     await this.ngrok?.stop();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping Ngrok!\n${ex}`);
        // }

        // try {
        //     if (this?.socket?.server) this.socket.server.close();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping the socket!\n${ex}`);
        // }

        // try {
        //     await this.iMessageRepo?.db?.close();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping the iMessage database connection!\n${ex}`);
        // }

        try {
            if (this.globalConfig?.dbConn?.isConnected) {
                await this.globalConfig?.dbConn?.close();
            }
        } catch (ex) {
            this.logger.error(`There was an issue stopping the server database connection!\n${ex}`);
        }

        // try {
        //     await this.contactsRepo?.db?.close();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping the contacts database connection!\n${ex}`);
        // }

        // try {
        //     if (this.networkChecker) this.networkChecker.stop();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping the network checker service!\n${ex}`);
        // }

        // try {
        //     FCMService.stop();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping the FCM service!\n${ex}`);
        // }

        // try {
        //     if (this.caffeinate) this.caffeinate.stop();
        // } catch (ex) {
        //     this.logger.error(`There was an issue stopping the caffeinate service!\n${ex}`);
        // }
    }

    async restartViaTerminal() {
        this.isRestarting = true;

        // Close everything gracefully
        await this.stopServices();

        // Kick off the restart script
        FileSystem.executeAppleScript(runTerminalScript(process.execPath));

        // Exit the current instance
        app.exit(0);
    }
}
