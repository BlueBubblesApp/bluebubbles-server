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
        await this.initializeDatabase();
        await this.setupDefaults();
        this.setupFileSystem();

        // Load DB
        const cfg = await this.db.getRepository(Config).find();
        cfg.forEach((item) => {
            this.config[item.name] = item.value;
        });

        await this.setupMessageRepo();

        // Setup services
        this.socketService = new SocketService(
            this.db,
            this.iMessageRepo,
            this.fs,
            this.config.socket_port
        );

        this.fcmService = new FCMService(this.fs);

        // Order matters
        await this.connectToNgrok();
    }

    async start(): Promise<void> {
        await this.setup();

        this.socketService.start();
        this.fcmService.start();
        this.startChatListener();
        this.startIpcListener();
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

        this.sendNotification("new-server", this.ngrokServer);
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

            this.fcmService.sendNotification(devices.map(device => device.identifier), {
                type,
                data
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
        const listener = new MessageListener(
            this.iMessageRepo,
            Number(this.config.poll_frequency)
        );
        listener.start();
        listener.on("new-entry", async (item: Message) => {
            console.log(
                `New message from ${item.from.id}, sent to ${item.chats[0].chatIdentifier}`
            );

            const msg = getMessageResponse(item);

            // Emit it to the socket
            this.socketService.socketServer.emit("new-message", msg);
            this.sendNotification("new-message", msg);
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

        ipcMain.handle("set-fcm-server", (event, args) => {
            this.fs.saveFCMServer(args);
            this.fcmService.start();
        });

        ipcMain.handle("set-fcm-client", (event, args) => {
            this.fs.saveFCMClient(args);
        });

        ipcMain.handle("get-fcm-server", (event, args) => {
            return this.fs.getFCMServer();
        });

        ipcMain.handle("get-fcm-client", (event, args) => {
            return this.fs.getFCMClient();
        });
    }
}
