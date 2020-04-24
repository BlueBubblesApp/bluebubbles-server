import * as io from "socket.io";

// Internal libraries
import { DatabaseRepository } from "@server/api/imessage";
import { ActionHandler } from "@server/helpers/actions";
import { FileSystem } from "@server/fileSystem";

// Helpers
import { ResponseFormat } from "@server/helpers/dataTypes";
import { createSuccessResponse, createServerErrorResponse, createBadRequestResponse, createNoDataResponse } from "@server/helpers/responses";

// Entities
import { Chat, getChatResponse } from "@server/api/imessage/entity/Chat";
import { getHandleResponse } from "@server/api/imessage/entity/Handle";
import { getMessageResponse } from "@server/api/imessage/entity/Message";
import { Connection } from "typeorm";
import { Device } from "@server/entity/Device";

export class SocketService {
    db: Connection;

    socketServer: io.Server;

    iMessageRepo: DatabaseRepository;

    fs: FileSystem;

    actionHandler: ActionHandler;

    constructor(
        db: Connection,
        iMessageRepo: DatabaseRepository,
        fs: FileSystem,
        port: number
    ) {
        this.db = db;
        this.socketServer = io(port);
        this.iMessageRepo = iMessageRepo;
        this.fs = fs;
        this.actionHandler = new ActionHandler(
            this.fs,
            this.iMessageRepo
        );
    }

    start() {
        /**
        * Handle all other data requests
        */
        this.socketServer.on("connection", async (socket) => {
            console.log("client connected");

            // Setup error handler middleware
            socket.use((packet, next) => {
                try {
                    next();
                } catch (ex) {
                    console.error(ex);
                    socket.error(createServerErrorResponse(ex.message));
                }
            });

            // Pass to method to handle the socket events
            this.routeSocket(socket);
        });
    }

    routeSocket(socket: io.Socket) {
        const respond = (
            callback: Function | null,
            channel: string | null,
            data: ResponseFormat
        ): void => {
            if (callback) callback(data);
            else socket.emit(channel, data);
        };

        /**
        * Add Device ID to
        */
        socket.on("add-fcm-device-id", async (params, cb): Promise<void> => {
            if (!params?.deviceId)
                return respond(cb, "error", createBadRequestResponse("No device ID specified"));

            const device = await this.db.getRepository(Device).findOne({ identifier: params.deviceId });
            if (device)
                return respond(cb, "fcm-device-id-added", createSuccessResponse(null, "Device ID already exists"))
            
            const item = new Device();
            item.identifier = params.deviceId;
            await this.db.getRepository(Device).save(item);

            return respond(
                cb,
                "fcm-device-id-added",
                createSuccessResponse(null, "Successfully added device ID")
            );
        });

        /**
        * Get all chats
        */
        socket.on("get-chats", async (params, cb) => {
            const chats = await this.iMessageRepo.getChats(null, true);
            respond(
                cb,
                "chats",
                createSuccessResponse(
                    chats.map((item) => getChatResponse(item))
                )
            );
        });

        /**
        * Get messages in a chat
        */
        socket.on(
            "get-chat-messages",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No chat identifier provided"
                        )
                    );

                const chats = await this.iMessageRepo.getChats(
                    params?.identifier,
                    true
                );

                if (!chats || chats.length === 0)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("Chat does not exist")
                    );

                const messages = await this.iMessageRepo.getMessages(
                    chats[0],
                    params?.offset || 0,
                    params?.limit || 100,
                    params?.after,
                    params?.before
                );

                return respond(
                    cb,
                    "chat-messages",
                    createSuccessResponse(
                        messages.map((item) => getMessageResponse(item))
                    )
                );
            }
        );

        /**
        * Get last message in a chat
        */
        socket.on(
            "get-last-chat-message",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No chat identifier provided"
                        )
                    );

                const chats = await this.iMessageRepo.getChats(
                    params?.identifier,
                    true
                );

                if (!chats || chats.length === 0)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("Chat does not exist")
                    );

                const messages = await this.iMessageRepo.getMessages(
                    chats[0],
                    0,
                    1
                );
                if (!messages || messages.length === 0)
                    return respond(
                        cb,
                        "last-chat-message",
                        createNoDataResponse()
                    );

                return respond(
                    cb,
                    "last-chat-message",
                    createSuccessResponse(
                        getMessageResponse(messages[0])
                    )
                );
            }
        );

        // /**
        //  * Get participants in a chat
        //  */
        socket.on(
            "get-participants",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No chat identifier provided"
                        )
                    );

                const chats = await this.iMessageRepo.getChats(
                    params?.identifier,
                    true
                );

                if (!chats || chats.length === 0)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("Chat does not exist")
                    );

                return respond(
                    cb,
                    "participants",
                    createSuccessResponse(
                        chats[0].participants.map((item) =>
                            getHandleResponse(item)
                        )
                    )
                );
            }
        );

        /**
        * Send message
        */
        socket.on(
            "send-message",
            async (params, cb): Promise<void> => {
                const chatGuid = params?.guid;
                const message = params?.message;

                if (!chatGuid || !message)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No chat GUID or message provided"
                        )
                    );

                await this.actionHandler.sendMessage(
                    chatGuid,
                    message,
                    params?.attachmentName,
                    params?.attachment
                );

                return respond(
                    cb,
                    "message-sent",
                    createSuccessResponse(null)
                );
            }
        );

        /**
        * Send message
        */
        socket.on(
            "start-chat",
            async (params, cb): Promise<void> => {
                let participants = params?.participants;

                if (!participants || participants.length === 0)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No participants specified"
                        )
                    );

                if (typeof participants === "string") {
                    participants = [participants];
                }

                if (!Array.isArray(participants)) {
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "Participant list must be an array"
                        )
                    );
                }

                const chatGuid = await this.actionHandler.createChat(
                    this.fs,
                    participants
                );

                try {
                    const newChat = await this.iMessageRepo.db
                        .getRepository(Chat)
                        .findOneOrFail({ guid: chatGuid });
                    return respond(
                        cb,
                        "chat-started",
                        createSuccessResponse(getChatResponse(newChat))
                    );
                } catch (ex) {
                    throw new Error("Failed to create new chat!");
                }
            }
        );

        // /**
        //  * Send reaction
        //  */
        socket.on(
            "send-reaction",
            async (params, cb): Promise<void> => {
                respond(
                    cb,
                    "reaction-sent",
                    createBadRequestResponse(
                        "This action has not yet been implemented"
                    )
                );
            }
        );

        socket.on("disconnect", () => {
            console.log(`Client ${socket.id} disconnected!`);
        });
    }

    restart(port: number) {
        this.socketServer.close();
        this.socketServer = io(port);
        this.start();
    }
}
