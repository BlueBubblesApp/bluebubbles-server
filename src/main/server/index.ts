import { app, ipcMain, BrowserWindow } from "electron";
import { createConnection, Connection, Repository } from "typeorm";
import * as io from "socket.io";
import * as ngrok from "ngrok";

import { Config } from "@server/entity/Config";
import { FileSystem } from "@server/fileSystem";
import { DEFAULT_POLL_FREQUENCY_MS, DEFAULT_SOCKET_PORT } from "@server/constants";

import { DatabaseRepository } from "@server/api/imessage";
import { MessageListener } from "@server/api/imessage/listeners/messageListener";
import { Message } from "@server/api/imessage/entity/Message";
import { sendMessage, createChat } from "@server/helpers/actions";
import { server } from "@renderer/variables/general";

export class BlueBubbleServer {
    window: BrowserWindow;
    
    db: Repository<Config>;

    iMessageRepo: DatabaseRepository;

    ngrokServer: string;

    socketServer: io.Server;

    config: { [key: string]: any };

    fs: FileSystem;

    constructor(window: BrowserWindow) {
        this.window = window;
        this.db = null;
        this.iMessageRepo = null;
        this.socketServer = null;
        this.ngrokServer = null;
        this.config = {};
        this.fs = null;
    }

    async setup(): Promise<void> {
        await this.initializeDatabase();
        await this.setupDefaults();
        this.setupFileSystem();

        // Load DB
        const cfg = await this.db.find();
        cfg.forEach((item) => {
            this.config[item.name] = item.value;
        });

        await this.connectToNgrok();
        await this.setupMessageRepo();
    }

    startChatListener() {
        // Create a listener to listen for new messages
        const listener = new MessageListener(
            this.iMessageRepo,
            Number(this.config.poll_frequency)
        );
        listener.start();
        listener.on("new-entry", (item: Message) => {
            console.log(
                `New message from ${item.from.id}, sent to ${item.chats[0].chatIdentifier}`
            );

            this.socketServer.emit("new-message", item);
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
                        await this.socketServer.close();
                        this.startSockets();
                    }
                }
                // Update in class
                if (this.config[item]) 
                
                // Update in DB
                await this.db.update({ name: item }, { value: args[item] })
            })

            this.window.webContents.send("config-update", this.config);
            return this.config;
        });

        ipcMain.handle("set-fcm-server", (event, args) => {
            this.fs.saveFCMServer(args);
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

    startSockets() {
        this.socketServer = io(this.config.socket_port);

        /**
        * Handle all other data requests
        */
        this.socketServer.on("connection", async (socket) => {
            console.log("client connected");

            socket.use((packet, next) => {
                try {
                    next()
                } catch (ex) {
                    console.error(ex);
                    socket.error(ex);
                }
            });

            /**
            * Get all chats
            */
            socket.on("get-chats", async (params, send_response) => {
                const chats = await this.iMessageRepo.getChats(
                    null,
                    true
                );

                if (send_response) send_response(chats);
                else socket.emit("chats", chats);
            });

            /**
            * Get messages in a chat
            */
            socket.on(
                "get-chat-messages",
                async (params, send_response) => {
                    if (!params?.identifier)
                        if (send_response)
                            send_response(null, "ERROR: No Identifier");
                        else
                            socket.emit("error", "ERROR: No Identifier");

                    const chats = await this.iMessageRepo.getChats(
                        params?.identifier,
                        true
                    );
                    const messages = await this.iMessageRepo.getMessages(
                        chats[0],
                        params?.offset || 0,
                        params?.limit || 100,
                        params?.after,
                        params?.before
                    );

                    if (send_response) send_response(messages);
                    else socket.emit("messages", messages);
                }
            );

            /**
            * Get last message in a chat
            */
            socket.on(
                "get-last-chat-message",
                async (params, send_response) => {
                    if (!params?.identifier)
                        if (send_response)
                            send_response(null, "ERROR: No Identifier");
                        else
                            socket.emit("error", "ERROR: No Identifier");

                    const chats = await this.iMessageRepo.getChats(
                        params?.identifier,
                        true
                    );
                    const messages = await this.iMessageRepo.getMessages(
                        chats[0],
                        0,
                        1
                    );

                    if (send_response) send_response(messages);
                    else socket.emit("last-chat-message", messages);
                }
            );

            // /**
            //  * Get participants in a chat
            //  */
            socket.on(
                "get-participants",
                async (params, send_response) => {
                    if (!params?.identifier)
                        if (send_response)
                            send_response("ERROR: No Identifier");
                        else
                            socket.emit("error", "ERROR: No Identifier");

                    const chats = await this.iMessageRepo.getChats(
                        params?.identifier,
                        true
                    );

                    if (send_response)
                        send_response(chats[0].participants);
                    else
                        socket.emit(
                            "participants",
                            chats[0].participants
                        );
                }
            );

            /**
            * Send message
            */
            socket.on("send-message", async (params, send_response): Promise<void> => {
                const chatGuid = params?.guid;
                const message = params?.message;

                if (!chatGuid || !message) {
                    socket.emit("error", "No chat GUID or message provided!");
                    return;
                }

                await sendMessage(this.fs, chatGuid, message, params?.attachmentName, params?.attachment);
            });

            /**
            * Send message
            */
            socket.on("start-chat", async (params, send_response): Promise<void> => {
                let participants = params?.participants;

                if (!participants || participants.length === 0) {
                    socket.error("No participants specified");
                    return;
                }

                if (typeof participants === "string") {
                    participants = [participants];
                }

                if (!Array.isArray(participants)) {
                    socket.error("Participants must be an array!");
                    return;
                }

                const chatGuid = await createChat(this.fs, participants);

                if (send_response) send_response(chatGuid)
                else socket.emit("new-chat", chatGuid);
            });

            // /**
            //  * Send reaction
            //  */
            socket.on("send-reaction", async (params, send_response) => {
                console.warn("Not Implemented: Reaction send request");
            });

            socket.on("disconnect", () => {
                console.log("Got disconnect!");
            });
        });
    }

    async initializeDatabase(): Promise<void> {
        const connection = await createConnection({
            type: "sqlite",
            database: `${app.getPath("userData")}/config.db`,
            entities: [Config],
            synchronize: true,
            logging: false
        });

        this.db = connection.getRepository(Config);
    }

    setupFileSystem(): void {
        this.fs = new FileSystem();
        this.fs.setup();
    }

    async setupDefaults(): Promise<void> {
        const frequency = await this.db.findOne({
            name: "poll_frequency"
        });
        if (!frequency)
            await this.addConfigItem(
                "poll_frequency",
                DEFAULT_POLL_FREQUENCY_MS
            );

        const socketPort = await this.db.findOne({
            name: "socket_port"
        });
        if (!socketPort)
            await this.addConfigItem("socket_port", DEFAULT_SOCKET_PORT);

        const serverAddress = await this.db.findOne({
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
        await this.db.update(
            { name: "server_address" },
            { value: this.ngrokServer }
        );
    }

    // eslint-disable-next-line class-methods-use-this
    async disconnectFromNgrok(): Promise<void> {
        await ngrok.disconnect();
    }

    async addConfigItem(
        name: string,
        value: string | number
    ): Promise<Config> {
        const item = new Config();
        item.name = name;
        item.value = String(value);
        await this.db.save(item);
        return item;
    }
}
