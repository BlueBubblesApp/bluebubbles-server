// Dependency Imports
import { app, ipcMain, BrowserWindow } from "electron";
import { createConnection, Connection } from "typeorm";
import * as ngrok from "ngrok";

// Configuration/Filesytem Imports
import { Config } from "@server/entity/Config";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS, DEFAULT_SOCKET_PORT } from "@server/constants";

// Database Imports
import { DatabaseRepository } from "@server/api/imessage";
import { MessageListener } from "@server/api/imessage/listeners/messageListener";
import { Message, getMessageResponse } from "@server/api/imessage/entity/Message";

// Service Imports
import { SocketService, FCMService } from "@server/services";
import { Device } from "@server/entity/Device";

import { generateUuid } from "@server/helpers/utils";
import { MessageUpdateListener } from "./api/imessage/listeners/messageUpdateListener";

/**
 * Main entry point for the back-end server
 * This will handle all services and helpers that get spun
 * up when running the application.
 */
export class BlueBubblesServer {
    window: BrowserWindow;
    
    db: Connection;

    iMessageRepo: DatabaseRepository;

    ngrokServer: string;

    socketService: SocketService;

    fcmService: FCMService;

    config: { [key: string]: any };

    fs: FileSystem;

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
        
        // Other helpers
        this.ngrokServer = null;
        this.config = {};
        this.fs = null;

        // Services
        this.socketService = null;
    }

    private emitToUI(event: string, data: any) {
        if (this.window)
            this.window.webContents.send(event, data);
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
                break;
            case "dir":
                console.dir(message);
                break;
            case "warn":
                console.warn(message);
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

        this.log("Starting socket service...");
        this.socketService.start();
        this.fcmService.start();

        this.log("Starting chat listener...");
        this.startChatListener();
        this.startIpcListener();

        this.log("Connecting to Ngrok...");
        await this.connectToNgrok();
    }

    /**
     * Sets a config value in the database and class
     *
     * @param name Name of the config item
     * @param value Value of the config item
     */
    private async setConfig(name: string, value: string): Promise<void> {
        await this.db.getRepository(Config).update({ name }, { value });
        this.config[name] = value;
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
        this.setupFileSystem();

        this.log("Initializing configuration database...");
        const cfg = await this.db.getRepository(Config).find();
        cfg.forEach((item) => {
            this.config[item.name] = item.value;
        });

        this.log("Connecting to iMessage database...");
        this.iMessageRepo = new DatabaseRepository();
        await this.iMessageRepo.initialize();

        this.log("Initializing up sockets...");
        this.socketService = new SocketService(
            this.db,
            this.iMessageRepo,
            this.fs,
            this.config.socket_port
        );

        this.log("Initializing connection to Google FCM...");
        this.fcmService = new FCMService(this.fs);
    }

    /**
     * Initializes the connection to the configuration database
     */
    private async initializeDatabase(): Promise<void> {
        this.db = await createConnection({
            type: "sqlite",
            database: `${app.getPath("userData")}/config.db`,
            entities: [Config, Device],
            synchronize: true,
            logging: false
        });
    }

    /**
     * Sets up the "filsystem". This basically initializes
     * the required directories for the app
     */
    private setupFileSystem(): void {
        this.fs = new FileSystem();
        this.fs.setup();
    }

    /**
     * This sets any default database values, if the database
     * has not already been initialized
     */
    private async setupDefaults(): Promise<void> {
        const tutorialIsDone = await this.db.getRepository(Config).findOne({
            name: "tutorial_is_done"
        });
        if (!tutorialIsDone)
            await this.addConfigItem("tutorial_is_done", 0);
        const socketPort = await this.db.getRepository(Config).findOne({
            name: "socket_port"
        });
        if (!socketPort)
            await this.addConfigItem("socket_port", DEFAULT_SOCKET_PORT);

        const serverAddress = await this.db.getRepository(Config).findOne({
            name: "server_address"
        });
        if (!serverAddress)
            await this.addConfigItem("server_address", "");

        const guid = await this.db.getRepository(Config).findOne({
            name: "guid"
        });
        if (!guid) await this.addConfigItem("guid", generateUuid());
    }

    /**
     * Sets up a connection to the Ngrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connectToNgrok(): Promise<void> {
        this.ngrokServer = await ngrok.connect({
            port: this.config.socket_port,
            // This is required to run ngrok in production
            binPath: (path) => path.replace("app.asar", "app.asar.unpacked")
        });

        await this.setConfig("server_address", this.ngrokServer);

        // Emit this over the socket
        if (this.socketService)
            this.socketService.socketServer.emit("new-server", this.ngrokServer);

        await this.sendNotification("new-server", this.ngrokServer);
        this.fcmService.setServerUrl(this.ngrokServer);
    }

    /**
     * Emits a notification to to your connected devices over FCM
     *
     * @param type The type of notification
     * @param data Associated data with the notification (as a string)
     */
    async sendNotification(type: string, data: any) {
        this.socketService.socketServer.emit("new-message", data);

        // Send notification to devices
        if (this.fcmService.app) {
            const devices = await this.db.getRepository(Device).find();
            if (!devices || devices.length === 0) return;

            const notifData = JSON.stringify(data);
            await this.fcmService.sendNotification(devices.map(device => device.identifier), {
                type,
                data: notifData
            });
        }
    }

    /**
     * Helper method for addind a new configuration item to the
     * database.
     *
     * @param name The name of the config item
     * @param value The initial value of the config item
     */
    private async addConfigItem(
        name: string,
        value: string | number
    ): Promise<Config> {
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
        // Create a listener to listen for new/updated messages
        const newMsgListener = new MessageListener(this.iMessageRepo, DEFAULT_POLL_FREQUENCY_MS);
        const updatedMsgListener = new MessageUpdateListener(this.iMessageRepo, DEFAULT_POLL_FREQUENCY_MS);

        newMsgListener.on("new-entry", async (item: Message) => {
            // ATTENTION: If "from" is null, it means you sent the message from a group chat
            // Check the isFromMe key prior to checking the "from" key
            const from = (item.isFromMe) ? "yourself" : item.from?.id
            const text = (item.cacheHasAttachments) ? `Image: ${item.text.slice(1, item.text.length) || "<No Text>"}` : item.text;
            this.log(`New message from [${from}]: [${text.substring(0, 50)}]`);

            const msg = getMessageResponse(item);

            // Emit it to the socket and FCM devices
            await this.sendNotification("new-message", msg);
        });

        updatedMsgListener.on("updated-entry", async (item: Message) => {
            // ATTENTION: If "from" is null, it means you sent the message from a group chat
            // Check the isFromMe key prior to checking the "from" key
            const from = (item.isFromMe) ? "yourself" : item.from?.id
            const time = item.dateDelivered || item.dateRead;
            const text = (item.dateRead) ? 'Text Read' : 'Text Delivered'
            this.log(`Updated message from [${from}]: [${text} -> ${time.toLocaleString()}]`);

            const msg = getMessageResponse(item);

            // Emit it to the socket and FCM devices
            await this.sendNotification("updated-message", msg);
        });
    }

    /**
     * Starts the inter-process-communication handlers. Basically, a router
     * for all requests sent by the Electron front-end
     */
    private startIpcListener() {
        ipcMain.handle("set-config", async (event, args) => {
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

        ipcMain.handle("get-config", async (event, args) => {
            const cfg = await this.db.getRepository(Config).find();
            for (const i of cfg) {
                this.config[i.name] = i.value;
            }

            return this.config;
        });

        ipcMain.handle("get-message-count", async (event, args) => {
            const count = await this.iMessageRepo.getMessageCount(args?.after, args?.before, args?.isFromMe);
            return count;
        });

        ipcMain.handle("get-chat-image-count", async (event, args) => {
            const count = await this.iMessageRepo.getChatImageCounts();
            return count;
        });

        ipcMain.handle("get-group-message-counts", async (event, args) => {
            const count = await this.iMessageRepo.getChatMessageCounts("group");
            return count;
        });

        ipcMain.handle("get-individual-message-counts", async (event, args) => {
            const count = await this.iMessageRepo.getChatMessageCounts("individual");
            return count;
        });

        ipcMain.handle("set-fcm-server", (event, args) => {
            this.fs.saveFCMServer(args);
            this.fcmService.start();
        });

        ipcMain.handle("set-fcm-client", (event, args) => {
            this.fs.saveFCMClient(args);
        });

        ipcMain.handle("get-devices", async (event, args) => {
            const devices = await this.db.getRepository(Device).find();
            return devices;
        });

        ipcMain.handle("get-fcm-server", (event, args) => {
            return this.fs.getFCMServer();
        });

        ipcMain.handle("get-fcm-client", (event, args) => {
            return this.fs.getFCMClient();
        });

        ipcMain.handle("complete-tutorial", async (event, args) => {
            await this.setConfig("tutorial_is_done", "1");
        });
    }
}
