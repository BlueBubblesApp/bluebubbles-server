import * as io from "socket.io";
import * as path from "path";
import * as fslib from "fs";
import * as zlib from "zlib";
import * as base64 from "byte-base64";

// Internal libraries
import { Server } from "@server/index";
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
import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse } from "@server/databases/imessage/entity/Handle";
import { getMessageResponse } from "@server/databases/imessage/entity/Message";
import { Device } from "@server/databases/server/entity/Device";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { DBMessageParams } from "@server/databases/imessage/types";
import { Queue } from "@server/databases/server/entity/Queue";
import { ActionHandler } from "@server/helpers/actions";

/**
 * This service class handles all routing for incoming socket
 * connections and requests.
 */
export class SocketService {
    server: io.Server;

    /**
     * Starts up the initial Socket.IO connection and initializes other
     * required classes and variables
     *
     * @param db The configuration database
     * @param server The iMessage database repository
     * @param fs The filesystem class handler
     * @param port The initial port for Socket.IO
     */
    constructor() {
        this.server = io(Server().repo.getConfig("socket_port"), {
            // 5 Minute ping timeout
            pingTimeout: 60000
        });
    }

    /**
     * Creates the initial connection handler for Socket.IO
     */
    start() {
        this.server.on("connect", () => {
            // Once we boot up, let's send a hello-world to all the clients
            Server().emitMessage("hello-world", null);
        });

        /**
         * Handle all other data requests
         */
        this.server.on("connection", async socket => {
            const pass = socket.handshake.query?.password ?? socket.handshake.query?.guid;
            const cfgPass = (await Server().repo.getConfig("password")) as string;

            // Basic authentication
            if (pass === cfgPass) {
                Server().log(`Client Authenticated Successfully`);
            } else {
                socket.disconnect();
                Server().log(`Closing client connection. Authentication failed.`);
            }

            /**
             * Error handling middleware for all Socket.IO requests.
             * If there are any errors in a socket event, they will be handled here.
             *
             * A console message will be printed, and a socket error will be emitted
             */
            socket.use((_, next) => {
                try {
                    next();
                } catch (ex) {
                    Server().log(`Socket server error! ${ex.message}`, "error");
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
        const respond = (callback: Function | null, channel: string | null, data: ResponseFormat): void => {
            if (callback) callback(data);
            else socket.emit(channel, data);

            if (data.error) Server().log(data.error.message, "error");
        };

        /**
         * Add Device ID to the database
         */
        socket.on(
            "add-fcm-device",
            async (params, cb): Promise<void> => {
                if (!params?.deviceName || !params?.deviceId)
                    return respond(cb, "error", createBadRequestResponse("No device name or ID specified"));

                // If the device ID exists, update the identifier
                const device = await Server().repo.devices().findOne({ name: params.deviceName });
                if (device) {
                    device.identifier = params.deviceId;
                    await Server().repo.devices().save(device);
                } else {
                    const item = new Device();
                    item.name = params.deviceName;
                    item.identifier = params.deviceId;
                    await Server().repo.devices().save(item);
                }

                return respond(cb, "fcm-device-id-added", createSuccessResponse(null, "Successfully added device ID"));
            }
        );

        /**
         * Add Device ID to the database
         */
        socket.on(
            "get-fcm-data",
            async (params, cb): Promise<void> => {
                if (!this) return respond(cb, "error", createBadRequestResponse("No device name or ID specified"));

                // If the device ID exists, update the identifier
                const device = await Server().repo.devices().findOne({ name: params.deviceName });
                if (device) {
                    await Server().repo.devices().update({ name: params.deviceName }, { identifier: params.deviceId });
                } else {
                    const item = new Device();
                    item.name = params.deviceName;
                    item.identifier = params.deviceId;
                    await Server().repo.devices().save(item);
                }

                return respond(cb, "fcm-device-id-added", createSuccessResponse(null, "Successfully added device ID"));
            }
        );

        /**
         * Get all chats
         */
        socket.on("get-chats", async (params, cb) => {
            const withParticipants = params?.withParticipants ?? true;
            const withArchived = params?.withArchived ?? false;
            const offset = params?.offset ?? 0;
            const limit = params?.offset ?? null;
            const chats = await Server().iMessageRepo.getChats({ withParticipants, withArchived, limit, offset });

            const results = [];
            for (const chat of chats ?? []) {
                const chatRes = await getChatResponse(chat);
                results.push(chatRes);
            }

            respond(cb, "chats", createSuccessResponse(results));
        });

        /**
         * Get single chat
         */
        socket.on("get-chat", async (params, cb) => {
            const chatGuid = params?.chatGuid;
            const withParticipants = params?.withParticipants ?? true;

            if (!chatGuid) return respond(cb, "error", createBadRequestResponse("No chat GUID provided"));

            const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants });
            return respond(cb, "chat", createSuccessResponse(await getChatResponse(chats[0])));
        });

        /**
         * Get messages in a chat
         */
        socket.on(
            "get-chat-messages",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(cb, "error", createBadRequestResponse("No chat identifier provided"));

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier });
                if (!chats || chats.length === 0)
                    return respond(cb, "error", createBadRequestResponse("Chat does not exist"));

                const dbParams: DBMessageParams = {
                    chatGuid: chats[0].guid,
                    offset: params?.offset ?? 0,
                    limit: params?.limit ?? 100,
                    after: params?.after,
                    before: params?.before,
                    withChats: params?.withChats ?? false,
                    withAttachments: params?.withAttachments ?? true,
                    withHandle: params?.withHandle ?? true,
                    sort: params?.sort ?? "DESC"
                };

                if (params?.where) dbParams.where = params.where;

                const messages = await Server().iMessageRepo.getMessages(dbParams);

                const withBlurhash = params?.withBlurhash ?? false;
                const results = [];
                for (const msg of messages) {
                    const msgRes = await getMessageResponse(msg, withBlurhash);
                    results.push(msgRes);
                }

                return respond(cb, "chat-messages", createSuccessResponse(results));
            }
        );

        /**
         * Get an attachment by guid
         */
        socket.on(
            "get-attachment",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(cb, "error", createBadRequestResponse("No attachment identifier provided"));

                const attachment = await Server().iMessageRepo.getAttachment(params?.identifier, params?.withMessages);
                if (!attachment) return respond(cb, "error", createBadRequestResponse("Attachment does not exist"));

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
                    return respond(cb, "error", createBadRequestResponse("No attachment identifier provided"));

                // Get the start, with fallbacks to 0
                let start = params?.start ?? 0;
                if (!Number.isInteger(start) || start < 0) start = 0;

                // Pull out the chunk size, falling back to 1024
                const chunkSize = params?.chunkSize ?? 1024;
                const compress = params?.compress ?? false;

                // Get the corresponding attachment
                const attachment = await Server().iMessageRepo.getAttachment(params?.identifier, false);
                if (!attachment) return respond(cb, "error", createBadRequestResponse("Attachment does not exist"));

                // Get the fully qualified path
                let fPath = attachment.filePath;
                if (fPath[0] === "~") {
                    fPath = path.join(process.env.HOME, fPath.slice(1));
                }

                // Get data as a Uint8Array
                let data = FileSystem.readFileChunk(fPath, start, chunkSize);
                if (compress) data = Uint8Array.from(zlib.deflateSync(data));

                if (!data) {
                    return respond(cb, "attachment-chunk", createNoDataResponse());
                }

                // Convert data to a base64 string
                return respond(cb, "attachment-chunk", createSuccessResponse(base64.bytesToBase64(data)));
            }
        );

        /**
         * Get last message in a chat
         */
        socket.on(
            "get-last-chat-message",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(cb, "error", createBadRequestResponse("No chat identifier provided"));

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier });
                if (!chats || chats.length === 0)
                    return respond(cb, "error", createBadRequestResponse("Chat does not exist"));

                const messages = await Server().iMessageRepo.getMessages({
                    chatGuid: chats[0].guid,
                    limit: 1
                });
                if (!messages || messages.length === 0) return respond(cb, "last-chat-message", createNoDataResponse());

                const result = await getMessageResponse(messages[0]);
                return respond(cb, "last-chat-message", createSuccessResponse(result));
            }
        );

        // /**
        //  * Get participants in a chat
        //  */
        socket.on(
            "get-participants",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return respond(cb, "error", createBadRequestResponse("No chat identifier provided"));

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier });

                if (!chats || chats.length === 0)
                    return respond(cb, "error", createBadRequestResponse("Chat does not exist"));

                const handles = [];
                for (const handle of chats[0].participants ?? []) {
                    const handleRes = await getHandleResponse(handle);
                    handles.push(handleRes);
                }

                return respond(cb, "participants", createSuccessResponse(handles));
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

                if (!chatGuid) return respond(cb, "error", createBadRequestResponse("No chat GUID provided"));

                if ((tempGuid && (!message || message.length === 0)) || (!tempGuid && message))
                    return respond(cb, "error", createBadRequestResponse("No temporary GUID provided with message"));

                if (params?.attachment && (!params.attachmentName || !params.attachmentGuid))
                    return respond(cb, "error", createBadRequestResponse("No attachment name or GUID provided"));

                try {
                    await ActionHandler.sendMessage(
                        tempGuid,
                        chatGuid,
                        message,
                        params?.attachmentGuid,
                        params?.attachmentName,
                        params?.attachment ? base64.base64ToBytes(params.attachment) : null
                    );

                    return respond(cb, "message-sent", createSuccessResponse(null));
                } catch (ex) {
                    return respond(cb, "send-message-error", createServerErrorResponse(ex.message));
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
                let message = params?.message;

                if (!chatGuid) return respond(cb, "error", createBadRequestResponse("No chat GUID provided"));
                if (!tempGuid) return respond(cb, "error", createBadRequestResponse("No temporary GUID provided"));

                // Attachment chunk parameters
                const attachmentGuid = params?.attachmentGuid;
                const attachmentChunkStart = params?.attachmentChunkStart;
                const attachmentData = params?.attachmentData;
                const hasMore = params?.hasMore;

                // Save the attachment chunk if there is an attachment
                if (attachmentGuid)
                    FileSystem.saveAttachmentChunk(
                        attachmentGuid,
                        attachmentChunkStart,
                        base64.base64ToBytes(attachmentData)
                    );

                // If it's the last chunk, but no message, default it to an empty string
                if (!hasMore && !message) message = "";
                if (!hasMore && !tempGuid && (!message || message.length === 0))
                    return respond(cb, "error", createBadRequestResponse("No temp GUID provided with message!"));

                // If it's the last chunk, make sure there is a message
                if (!hasMore && attachmentGuid && !params?.attachmentName)
                    return respond(cb, "error", createBadRequestResponse("No attachment name provided"));

                // If there are no more chunks, compile, save, and send
                if (!hasMore) {
                    try {
                        await ActionHandler.sendMessage(
                            tempGuid,
                            chatGuid,
                            message,
                            attachmentGuid,
                            params?.attachmentName,
                            attachmentGuid ? FileSystem.buildAttachmentChunks(attachmentGuid) : null
                        );

                        FileSystem.deleteChunks(attachmentGuid);
                        return respond(cb, "message-sent", createSuccessResponse(null));
                    } catch (ex) {
                        return respond(cb, "send-message-chunk-error", createServerErrorResponse(ex.message));
                    }
                }

                return respond(cb, "message-chunk-saved", createSuccessResponse(null));
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
                    return respond(cb, "error", createBadRequestResponse("No participants specified"));

                if (typeof participants === "string") {
                    participants = [participants];
                }

                if (!Array.isArray(participants))
                    return respond(cb, "error", createBadRequestResponse("Participant list must be an array"));

                const chatGuid = await ActionHandler.createChat(participants);

                try {
                    const newChat = await Server().iMessageRepo.getChats({ chatGuid });
                    return respond(cb, "chat-started", createSuccessResponse(await getChatResponse(newChat[0])));
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
                    return respond(cb, "error", createBadRequestResponse("No chat identifier provided"));
                if (!params?.newName)
                    return respond(cb, "error", createBadRequestResponse("No new group name provided"));

                try {
                    await ActionHandler.renameGroupChat(params.identifier, params.newName);

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                    return respond(cb, "group-renamed", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex) {
                    return respond(cb, "rename-group-error", createServerErrorResponse(ex.message));
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
                    return respond(cb, "error", createBadRequestResponse("No chat identifier provided"));
                if (!params?.address)
                    return respond(cb, "error", createBadRequestResponse("No participant address specified"));

                try {
                    const result = await ActionHandler.addParticipant(params.identifier, params.address);
                    if (result.trim() !== "success") return respond(cb, "error", createBadRequestResponse(result));

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                    return respond(cb, "participant-added", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex) {
                    return respond(cb, "add-participant-error", createServerErrorResponse(ex.message));
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
                    return respond(cb, "error", createBadRequestResponse("No chat identifier provided"));
                if (!params?.address)
                    return respond(cb, "error", createBadRequestResponse("No participant address specified"));

                try {
                    const result = await ActionHandler.removeParticipant(params.identifier, params.address);
                    if (result.trim() !== "success") return respond(cb, "error", createBadRequestResponse(result));

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                    return respond(cb, "participant-removed", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex) {
                    return respond(cb, "remove-participant-error", createServerErrorResponse(ex.message));
                }
            }
        );

        // /**
        //  * Send reaction
        //  */
        socket.on(
            "send-reaction",
            async (params, cb): Promise<void> => {
                if (!params?.chatGuid) return respond(cb, "error", createBadRequestResponse("No chat GUID provided!"));
                if (!params?.message) return respond(cb, "error", createBadRequestResponse("No message provided!"));
                if (!params?.actionMessage)
                    return respond(cb, "error", createBadRequestResponse("No action message provided!"));
                if (!params?.tapback || !["love", "like", "dislike", "question", "emphasize"].includes(params.tapback))
                    return respond(cb, "error", createBadRequestResponse("Invalid tapback descriptor provided!"));

                // Add the reaction to the match queue
                const item = new Queue();
                item.tempGuid = params.message.guid;
                item.chatGuid = params.chatGuid;
                item.dateCreated = new Date().getTime();
                item.text = params.message.text;
                await Server().repo.queue().manager.save(item);

                try {
                    await ActionHandler.toggleTapback(params.chatGuid, params.actionMessage.text, params.tapback);
                    return respond(cb, "tapback-sent", createNoDataResponse());
                } catch (ex) {
                    return respond(cb, "send-tapback-error", createServerErrorResponse(ex.message));
                }
            }
        );

        /**
         * Gets a contact (or contacts) for a given list of handles, from the database
         */
        socket.on(
            "get-contacts-from-db",
            async (params, cb): Promise<void> => {
                if (!Server().contactsRepo || !Server().contactsRepo.db.isConnected) {
                    respond(cb, "contacts", createServerErrorResponse("Contacts repository is disconnected!"));
                    return;
                }

                const handles = params;
                for (let i = 0; i <= handles.length; i += 1) {
                    if (!handles[i] || !handles[i].address) continue;
                    const contact = await Server().contactsRepo.getContactByAddress(handles[i].address);
                    if (contact) {
                        handles[i].firstName = contact.firstName;
                        handles[i].lastName = contact.lastName;
                    }
                }

                respond(cb, "contacts-from-disk", createSuccessResponse(handles));
            }
        );

        /**
         * Gets a contacts
         */
        socket.on(
            "get-contacts-from-vcf",
            async (_, cb): Promise<void> => {
                try {
                    // Export the contacts
                    await ActionHandler.exportContacts();

                    // Check if the contacts export exists, and respond back with it
                    const contactsPath = path.join(FileSystem.contactsDir, "AddressBook.vcf");
                    if (fslib.existsSync(contactsPath)) {
                        const data = fslib.readFileSync(contactsPath).toString("utf-8");
                        respond(cb, "contacts-from-vcf", createSuccessResponse(data));
                    } else {
                        respond(cb, "contacts-from-vcf", createServerErrorResponse("Failed to export Address Book!"));
                    }
                } catch (ex) {
                    respond(cb, "contacts-from-vcf", createServerErrorResponse(ex.message));
                }
            }
        );

        socket.on("disconnect", () => {
            Server().log(`Client ${socket.id} disconnected!`);
        });
    }

    /**
     * Restarts the Socket.IO connection with a new port
     *
     * @param port The new port to listen on
     */
    restart() {
        if (this.server) {
            this.server.close();
            this.server = io(Server().repo.getConfig("socket_port"), {
                // 5 Minute ping timeout
                pingTimeout: 60000
            });
        }

        this.start();
    }
}
