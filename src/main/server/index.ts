import { app, ipcMain, BrowserWindow } from "electron";
import { createConnection, Connection } from "typeorm";
import * as ngrok from "ngrok";

import { Config } from "@server/entity/Config";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS, DEFAULT_SOCKET_PORT } from "@server/constants";

import { DatabaseRepository } from "@server/api/imessage";
import { MessageListener } from "@server/api/imessage/listeners/messageListener";
import { Message, getMessageResponse } from "@server/api/imessage/entity/Message";

// Service Imports
import { SocketService, FCMService } from "@server/services";
import { Device } from "./entity/Device";

export class BlueBubbleServer {
    window: BrowserWindow;
    
    db: Connection;

    iMessageRepo: DatabaseRepository;

    ngrokServer: string;

    socketService: SocketService;

    fcmService: FCMService;

    config: { [key: string]: any };

    fs: FileSystem;

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

    async setup(): Promise<void> {
        console.log("Performing initial setup...");
        await this.initializeDatabase();
        await this.setupDefaults();
        this.setupFileSystem();

        console.log("Initializing configuration database...");
        const cfg = await this.db.getRepository(Config).find();
        cfg.forEach((item) => {
            this.config[item.name] = item.value;
        });

        console.log("Connecting to iMessage database...");
        await this.setupMessageRepo();

        console.log("Initializing up sockets...");
        this.socketService = new SocketService(
            this.db,
            this.iMessageRepo,
            this.fs,
            this.config.socket_port
        );

        console.log("Initializing connection to Google FCM...");
        this.fcmService = new FCMService(this.fs);
    }

    async start(): Promise<void> {
        await this.setup();

        console.log("Starting socket service...");
        this.socketService.start();
        this.fcmService.start();

        console.log("Starting chat listener...");
        this.startChatListener();
        this.startIpcListener();

        console.log("Connecting to Ngrok...");
        await this.connectToNgrok();
    }

    async initializeDatabase(): Promise<void> {
        this.db = await createConnection({
            type: "sqlite",
            database: `${app.getPath("userData")}/config.db`,
            entities: [Config, Device],
            synchronize: true,
            logging: false
        });
    }

    setupFileSystem(): void {
        this.fs = new FileSystem();
        this.fs.setup();
    }

    async setupDefaults(): Promise<void> {
        const frequency = await this.db.getRepository(Config).findOne({
            name: "poll_frequency"
        });
        if (!frequency)
            await this.addConfigItem(
                "poll_frequency",
                DEFAULT_POLL_FREQUENCY_MS
            );

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
    }

    async setupMessageRepo(): Promise<void> {
        this.iMessageRepo = new DatabaseRepository();
        await this.iMessageRepo.initialize();
    }

    async connectToNgrok(): Promise<void> {
        this.ngrokServer = await ngrok.connect(this.config.socket_port);
        this.config.server_address = this.ngrokServer;
        await this.db.getRepository(Config).update(
            { name: "server_address" },
            { value: this.ngrokServer }
        );

        // Emit this over the socket
        if (this.socketService)
            this.socketService.socketServer.emit("new-server", this.ngrokServer);

        await this.sendNotification("new-server", this.ngrokServer);
    }

    // eslint-disable-next-line class-methods-use-this
    async disconnectFromNgrok(): Promise<void> {
        await ngrok.disconnect();
    }

    async sendNotification(type: string, data: any) {
        // Send notification to devices
        if (this.fcmService.app) {
            const devices = await this.db.getRepository(Device).find();
            if (!devices || devices.length === 0) return;

            const notifData = JSON.stringify(data);
            console.log(notifData);
            await this.fcmService.sendNotification(devices.map(device => device.identifier), {
                type,
                data: notifData
            });
        }
    }

    async addConfigItem(
        name: string,
        value: string | number
    ): Promise<Config> {
        const item = new Config();
        item.name = name;
        item.value = String(value);
        await this.db.getRepository(Config).save(item);
        return item;
    }

    startChatListener() {
        // Create a listener to listen for new messages
        const listener = new MessageListener(this.iMessageRepo, Number(this.config.poll_frequency));
        listener.start();
        listener.on("new-entry", async (item: Message) => {
            // ATTENTION: If "from" is null, it means you sent the message from a group chat
            // Check the isFromMe key prior to checking the "from" key
            const from = (item.isFromMe) ? "yourself" : item.from?.id
            console.log(
                `New message from [${from}], sent to [${item.chats[0]?.displayName || item.chats[0]?.chatIdentifier}]`
            );

            const msg = getMessageResponse(item);

            // Emit it to the socket
            this.socketService.socketServer.emit("new-message", msg);
            await this.sendNotification("new-message", msg);
        });
    }

    startIpcListener() {
        ipcMain.handle("set-config", (event, args) => {
            Object.keys(args).forEach(async (item) => {
                if (this.config[item] && this.config[item] !== args[item]) {
                    this.config[item] = args[item];

                    // If the socket port changed, disconnect and reconnect
                    if (item === "socket_port") {
                        await this.disconnectFromNgrok();
                        await this.connectToNgrok();
                        await this.socketService.restart(args[item]);
                    }
                }
                // Update in class
                if (this.config[item]) 
                
                // Update in DB
                await this.db.getRepository(Config).update({ name: item }, { value: args[item] })
            })

            this.window.webContents.send("config-update", this.config);
            return this.config;
        });

        ipcMain.handle("get-message-count", async (event, args) => {
            const count = await this.iMessageRepo.getMessageCount(args?.after, args?.before);
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
    }
}
