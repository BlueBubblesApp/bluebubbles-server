import * as io from "socket.io";
import * as path from "path";
import * as zlib from "zlib";
import * as base64 from "byte-base64";

// Internal libraries
import { MessageRepository } from "@server/api/imessage";
import { ActionHandler } from "@server/helpers/actions";
import { FileSystem } from "@server/fileSystem";

// Helpers
import { ResponseFormat } from "@server/types";
import {
    createSuccessResponse,
    createServerErrorResponse,
    createBadRequestResponse,
    createNoDataResponse
} from "@server/helpers/responses";

// Entities
import { Chat, getChatResponse } from "@server/api/imessage/entity/Chat";
import { getHandleResponse } from "@server/api/imessage/entity/Handle";
import { getMessageResponse } from "@server/api/imessage/entity/Message";
import { Connection } from "typeorm";
import { Device } from "@server/entity/Device";
import { getAttachmentResponse } from "@server/api/imessage/entity/Attachment";
import { Config } from "@server/entity/Config";
import { ContactRepository } from "@server/api/contacts";

/**
 * This service class handles all routing for incoming socket
 * connections and requests.
 */
export class SocketService {
    db: Connection;

    socketServer: io.Server;

    iMessageRepo: MessageRepository;

    contactsRepo: ContactRepository;

    fs: FileSystem;

    actionHandler: ActionHandler;

    /**
     * Starts up the initial Socket.IO connection and initializes other
     * required classes and variables
     *
     * @param db The configuration database
     * @param iMessageRepo The iMessage database repository
     * @param fs The filesystem class handler
     * @param port The initial port for Socket.IO
     */
    constructor(
        db: Connection,
        iMessageRepo: MessageRepository,
        contactsRepo: ContactRepository,
        fs: FileSystem,
        port: number
    ) {
        this.db = db;

        this.socketServer = io(port, {
            // 5 Minute ping timeout
            pingTimeout: 60000
        });

        this.iMessageRepo = iMessageRepo;
        this.contactsRepo = contactsRepo;
        this.fs = fs;
        this.actionHandler = new ActionHandler(
            this.db,
            this.fs,
            this.iMessageRepo,
            this.contactsRepo
        );
    }

    /**
     * Creates the initial connection handler for Socket.IO
     */
    start() {
        /**
         * Handle all other data requests
         */
        this.socketServer.on("connection", async (socket) => {
            const guid = socket.handshake.query?.guid;
            const cfg = await this.db
                .getRepository(Config)
                .findOne({ name: "guid" });

            // Basic authentication
            if (guid === cfg.value) {
                console.log("Client Authenticated Successfully");
            } else {
                socket.disconnect();
                console.log(
                    "Closing client connection. Authentication failed."
                );
            }

            /**
             * Error handling middleware for all Socket.IO requests.
             * If there are any errors in a socket event, they will be handled here.
             *
             * A console message will be printed, and a socket error will be emitted
             */
            socket.use((packet, next) => {
                try {
                    // console.log(socket.request);
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

    /**
     * The rest of the socket event handlers
     *
     * @param socket The incoming socket connection
     */
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
         * Add Device ID to the database
         */
        socket.on(
            "add-fcm-device",
            async (params, cb): Promise<void> => {
                if (!params?.deviceName || !params?.deviceId)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No device name or ID specified"
                        )
                    );

                // If the device ID exists, update the identifier
                const device = await this.db
                    .getRepository(Device)
                    .findOne({ name: params.deviceName });
                if (device) {
                    await this.db
                        .getRepository(Device)
                        .update(
                            { name: params.deviceName },
                            { identifier: params.deviceId }
                        );
                } else {
                    const item = new Device();
                    item.name = params.deviceName;
                    item.identifier = params.deviceId;
                    await this.db.getRepository(Device).save(item);
                }

                return respond(
                    cb,
                    "fcm-device-id-added",
                    createSuccessResponse(null, "Successfully added device ID")
                );
            }
        );

        /**
         * Get all chats
         */
        socket.on("get-chats", async (params, cb) => {
            const withParticipants = params?.withParticipants ?? true;
            const chats = await this.iMessageRepo.getChats(
                null,
                withParticipants
            );

            const results = [];
            for (const chat of chats ?? []) {
                const chatRes = await getChatResponse(chat);
                results.push(chatRes);
            }

            respond(cb, "chats", createSuccessResponse(results));
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
                        createBadRequestResponse("No chat identifier provided")
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

                const messages = await this.iMessageRepo.getMessages({
                    chatGuid: chats[0].guid,
                    offset: params?.offset ?? 0,
                    limit: params?.limit ?? 100,
                    after: params?.after,
                    before: params?.before,
                    withChats: params?.withChats ?? false,
                    sort: params?.sort ?? "DESC"
                });

                const withBlurhash = params?.withBlurhash ?? false;
                const results = [];
                for (const msg of messages) {
                    const msgRes = await getMessageResponse(msg, withBlurhash);
                    results.push(msgRes);
                }

                return respond(
                    cb,
                    "chat-messages",
                    createSuccessResponse(results)
                );
            }
        );

        /**
         * Get an attachment by guid
         */
        socket.on(
            "get-attachment",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No attachment identifier provided"
                        )
                    );

                const attachment = await this.iMessageRepo.getAttachment(
                    params?.identifier,
                    params?.withMessages
                );
                if (!attachment)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("Attachment does not exist")
                    );

                const res = await getAttachmentResponse(attachment, true);
                return respond(cb, "attachment", createSuccessResponse(res));
            }
        );

        /**
         * Get an attachment chunk by guid
         */
        socket.on(
            "get-attachment-chunk",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No attachment identifier provided"
                        )
                    );

                // Get the start, with fallbacks to 0
                let start = params?.start ?? 0;
                if (!Number.isInteger(start) || start < 0) start = 0;

                // Pull out the chunk size, falling back to 1024
                const chunkSize = params?.chunkSize ?? 1024;
                const compress = params?.compress ?? false;

                // Get the corresponding attachment
                const attachment = await this.iMessageRepo.getAttachment(
                    params?.identifier,
                    false
                );
                if (!attachment)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("Attachment does not exist")
                    );

                // Get the fully qualified path
                let fPath = attachment.filePath;
                if (fPath[0] === "~") {
                    fPath = path.join(process.env.HOME, fPath.slice(1));
                }

                // Get data as a Uint8Array
                let data = FileSystem.readFileChunk(fPath, start, chunkSize);
                if (compress) data = Uint8Array.from(zlib.deflateSync(data));

                if (!data) {
                    return respond(
                        cb,
                        "attachment-chunk",
                        createNoDataResponse()
                    );
                }

                // Convert data to a base64 string
                return respond(
                    cb,
                    "attachment-chunk",
                    createSuccessResponse(base64.bytesToBase64(data))
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
                        createBadRequestResponse("No chat identifier provided")
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

                const messages = await this.iMessageRepo.getMessages({
                    chatGuid: chats[0].guid,
                    limit: 1
                });
                if (!messages || messages.length === 0)
                    return respond(
                        cb,
                        "last-chat-message",
                        createNoDataResponse()
                    );

                const result = await getMessageResponse(messages[0]);
                return respond(
                    cb,
                    "last-chat-message",
                    createSuccessResponse(result)
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
                        createBadRequestResponse("No chat identifier provided")
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

                const handles = [];
                for (const handle of chats[0].participants ?? []) {
                    const handleRes = await getHandleResponse(handle);
                    handles.push(handleRes);
                }

                return respond(
                    cb,
                    "participants",
                    createSuccessResponse(handles)
                );
            }
        );

        /**
         * Send message
         */
        socket.on(
            "send-message",
            async (params, cb): Promise<void> => {
                const tempGuid = params?.tempGuid;
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

                if (!tempGuid)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No temporary GUID provided")
                    );

                if (!params?.attachmentName && params?.attachment)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No attachment name provided")
                    );

                try {
                    await this.actionHandler.sendMessage(
                        tempGuid,
                        chatGuid,
                        message,
                        params?.attachmentName,
                        params?.attachment
                            ? base64.base64ToBytes(params.attachment)
                            : null
                    );

                    return respond(
                        cb,
                        "message-sent",
                        createSuccessResponse(null)
                    );
                } catch (ex) {
                    return respond(
                        cb,
                        "send-message-error",
                        createServerErrorResponse(ex.message)
                    );
                }
            }
        );

        /**
         * Send message with chunked attachment
         */
        socket.on(
            "send-message-chunk",
            async (params, cb): Promise<void> => {
                const chatGuid = params?.guid;
                const tempGuid = params?.tempGuid;
                const message = params?.message;

                if (!chatGuid)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No chat GUID provided")
                    );
                if (!tempGuid)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No temporary GUID provided")
                    );

                // Attachment chunk parameters
                const attachmentGuid = params?.attachmentGuid;
                const attachmentChunkStart = params?.attachmentChunkStart;
                const attachmentData = params?.attachmentData;
                const hasMore = params?.hasMore;

                // Save the attachment chunk if there is an attachment
                if (attachmentGuid)
                    this.fs.saveAttachmentChunk(
                        attachmentGuid,
                        attachmentChunkStart,
                        base64.base64ToBytes(attachmentData)
                    );

                // If it's the last chunk, make sure there is a message
                if (!hasMore && !message)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No message provided!")
                    );

                // If it's the last chunk, make sure there is a message
                if (!hasMore && attachmentGuid && !params?.attachmentName)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No attachment name provided")
                    );

                // If there are no more chunks, compile, save, and send
                if (!hasMore) {
                    try {
                        await this.actionHandler.sendMessage(
                            tempGuid,
                            chatGuid,
                            message,
                            params?.attachmentName,
                            attachmentGuid
                                ? this.fs.buildAttachmentChunks(attachmentGuid)
                                : null
                        );

                        this.fs.deleteChunks(attachmentGuid);
                        return respond(
                            cb,
                            "message-sent",
                            createSuccessResponse(null)
                        );
                    } catch (ex) {
                        return respond(
                            cb,
                            "send-message-chunk-error",
                            createServerErrorResponse(ex.message)
                        );
                    }
                }

                return respond(
                    cb,
                    "message-chunk-saved",
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
                        createBadRequestResponse("No participants specified")
                    );

                if (typeof participants === "string") {
                    participants = [participants];
                }

                if (!Array.isArray(participants))
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "Participant list must be an array"
                        )
                    );

                const chatGuid = await this.actionHandler.createChat(
                    participants
                );

                try {
                    const newChat = await this.iMessageRepo.getChats(
                        chatGuid,
                        true
                    );
                    return respond(
                        cb,
                        "chat-started",
                        createSuccessResponse(await getChatResponse(newChat[0]))
                    );
                } catch (ex) {
                    throw new Error("Failed to create new chat!");
                }
            }
        );

        /**
         * Renames a group chat
         */
        socket.on(
            "rename-group",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No chat identifier provided")
                    );
                if (!params?.newName)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No new group name provided")
                    );

                try {
                    await this.actionHandler.renameGroupChat(
                        params.identifier,
                        params.newName
                    );

                    const chats = await this.iMessageRepo.getChats(
                        params.identifier,
                        true
                    );
                    return respond(
                        cb,
                        "group-renamed",
                        createSuccessResponse(await getChatResponse(chats[0]))
                    );
                } catch (ex) {
                    return respond(
                        cb,
                        "rename-group-error",
                        createServerErrorResponse(ex.message)
                    );
                }
            }
        );

        /**
         * Adds a participant to a chat
         */
        socket.on(
            "add-participant",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No chat identifier provided")
                    );
                if (!params?.address)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No participant address specified"
                        )
                    );

                try {
                    const result = await this.actionHandler.addParticipant(
                        params.identifier,
                        params.address
                    );
                    if (result.trim() !== "success")
                        return respond(
                            cb,
                            "error",
                            createBadRequestResponse(result)
                        );

                    const chats = await this.iMessageRepo.getChats(
                        params.identifier,
                        true
                    );
                    return respond(
                        cb,
                        "participant-added",
                        createSuccessResponse(await getChatResponse(chats[0]))
                    );
                } catch (ex) {
                    return respond(
                        cb,
                        "add-participant-error",
                        createServerErrorResponse(ex.message)
                    );
                }
            }
        );

        /**
         * Removes a participant from a chat
         */
        socket.on(
            "remove-participant",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse("No chat identifier provided")
                    );
                if (!params?.address)
                    return respond(
                        cb,
                        "error",
                        createBadRequestResponse(
                            "No participant address specified"
                        )
                    );

                try {
                    const result = await this.actionHandler.removeParticipant(
                        params.identifier,
                        params.address
                    );
                    if (result.trim() !== "success")
                        return respond(
                            cb,
                            "error",
                            createBadRequestResponse(result)
                        );

                    const chats = await this.iMessageRepo.getChats(
                        params.identifier,
                        true
                    );
                    return respond(
                        cb,
                        "participant-removed",
                        createSuccessResponse(await getChatResponse(chats[0]))
                    );
                } catch (ex) {
                    return respond(
                        cb,
                        "remove-participant-error",
                        createServerErrorResponse(ex.message)
                    );
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

    /**
     * Restarts the Socket.IO connection with a new port
     *
     * @param port The new port to listen on
     */
    restart(port: number) {
        this.socketServer.close();
        this.socketServer = io(port);
        this.start();
    }
}
