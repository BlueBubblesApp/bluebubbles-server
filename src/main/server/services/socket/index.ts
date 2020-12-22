/* eslint-disable max-len */
import { app } from "electron";
import * as io from "socket.io";
import * as path from "path";
import * as fs from "fs";
import * as zlib from "zlib";
import * as base64 from "byte-base64";
import * as macosVersion from "macos-version";
import * as CryptoJS from "crypto-js";

// Internal libraries
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";

// Helpers
import { ResponseFormat, ServerMetadataResponse } from "@server/types";
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
import { QueueItem } from "@server/services/queue/index";
import { basename } from "path";

const osVersion = macosVersion();

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
        this.server = io(Server().repo.getConfig("socket_port") as number, {
            // 5 Minute ping timeout
            pingTimeout: 60000,
            path: "/"
        });

        this.startStatusListener();
    }

    /**
     * Checks to see if we are currently listening
     */
    startStatusListener() {
        setInterval(async () => {
            const port = Server().repo.getConfig("socket_port");

            // Check if there are any listening services
            let res = (await FileSystem.execShellCommand(`lsof -nP -iTCP -sTCP:LISTEN | grep ${port}`)) as string;
            res = (res ?? "").trim();

            // If the result doesn't show anything listening,
            if (!res.includes(port.toString())) {
                Server().log("Socket not listening! Restarting...", "error");
                this.restart();
            }
        }, 1000 * 60); // Check every minute
    }

    /**
     * Creates the initial connection handler for Socket.IO
     */
    start() {
        // Once we start, let's send a hello-world to all the clients
        Server().emitMessage("hello-world", null);

        /**
         * Handle all other data requests
         */
        this.server.on("connection", async socket => {
            let pass = socket.handshake.query?.password ?? socket.handshake.query?.guid;
            const cfgPass = (await Server().repo.getConfig("password")) as string;

            // Decode the param incase it contains URL encoded characters
            pass = decodeURI(pass);

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
            socket.use(async (_, next) => {
                try {
                    await next();
                } catch (ex) {
                    Server().log(`Socket server error! ${ex.message}`, "error");
                    socket.error(createServerErrorResponse(ex.message));
                }
            });

            // Pass to method to handle the socket events
            SocketService.routeSocket(socket);
        });
    }

    /**
     * The rest of the socket event handlers
     *
     * @param socket The incoming socket connection
     */
    static routeSocket(socket: io.Socket) {
        const response = (callback: Function | null, channel: string | null, data: ResponseFormat): void => {
            const resData = data;
            resData.encrypted = false;

            // Only encrypt coms enabled
            const encrypt = Server().repo.getConfig("encrypt_coms") as boolean;
            const passphrase = Server().repo.getConfig("password") as string;

            // Don't encrypt the attachment, it's already encrypted
            if (encrypt) {
                if (typeof data.data === "string" && channel !== "attachment-chunk") {
                    resData.data = CryptoJS.AES.encrypt(data.data, passphrase).toString();
                    resData.encrypted = true;
                } else if (channel !== "attachment-chunk") {
                    resData.data = CryptoJS.AES.encrypt(JSON.stringify(data.data), passphrase).toString();
                    resData.encrypted = true;
                }
            }

            if (callback) callback(resData);
            else socket.emit(channel, resData);

            if (data.error) Server().log(data.error.message, "error");
        };

        /**
         * Return information about the server
         */
        socket.on("get-server-metadata", (_, cb): void => {
            const meta: ServerMetadataResponse = {
                os_version: osVersion,
                server_version: app.getVersion()
            };

            return response(cb, "server-metadata", createSuccessResponse(meta, "Successfully fetched metadata"));
        });

        /**
         * Return information about the server's config
         */
        socket.on("get-server-config", (_, cb): void => {
            const { config } = Server().repo;

            // Strip out some stuff the user doesn't need
            if ("password" in config) delete config.password;
            if ("server_address" in config) delete config.server_address;

            return response(cb, "server-config", createSuccessResponse(config, "Successfully fetched server config"));
        });

        /**
         * Add Device ID to the database
         */
        socket.on(
            "add-fcm-device",
            async (params, cb): Promise<void> => {
                if (!params?.deviceName || !params?.deviceId)
                    return response(cb, "error", createBadRequestResponse("No device name or ID specified"));

                // If the device ID exists, update the identifier
                const device = await Server().repo.devices().findOne({ name: params.deviceName });
                if (device) {
                    device.identifier = params.deviceId;
                    device.last_active = new Date().getTime();
                    await Server().repo.devices().save(device);
                } else {
                    Server().log(`Registering new client with Google FCM (${params.deviceName})`);

                    const item = new Device();
                    item.name = params.deviceName;
                    item.identifier = params.deviceId;
                    item.last_active = new Date().getTime();
                    await Server().repo.devices().save(item);
                }

                Server().repo.purgeOldDevices();

                return response(cb, "fcm-device-id-added", createSuccessResponse(null, "Successfully added device ID"));
            }
        );

        /**
         * Gets the FCM client config data
         */
        socket.on(
            "get-fcm-client",
            async (_, cb): Promise<void> => {
                return response(
                    cb,
                    "fcm-client",
                    createSuccessResponse(FileSystem.getFCMClient(), "Successfully got FCM data")
                );
            }
        );

        /**
         * Handles a server ping
         */
        socket.on(
            "get-logs",
            async (params, cb): Promise<void> => {
                const count = params?.count ?? 100;
                const logs = await FileSystem.getLogs({ count });
                return response(cb, "logs", createSuccessResponse(logs));
            }
        );

        /**
         * Get all chats
         */
        socket.on("get-chats", async (params, cb) => {
            const chats = await Server().iMessageRepo.getChats({
                withParticipants: params?.withParticipants ?? true,
                withArchived: params?.withArchived ?? false,
                withSMS: params?.withSMS ?? false,
                limit: params?.limit ?? null,
                offset: params?.offset ?? 0
            });

            const results = [];
            for (const chat of chats ?? []) {
                const chatRes = await getChatResponse(chat);
                results.push(chatRes);
            }

            response(cb, "chats", createSuccessResponse(results));
        });

        /**
         * Get single chat
         */
        socket.on("get-chat", async (params, cb) => {
            const chatGuid = params?.chatGuid;
            if (!chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided"));

            const chats = await Server().iMessageRepo.getChats({
                chatGuid,
                withParticipants: params?.withParticipants ?? true,
                withSMS: true
            });
            if (chats.length === 0) {
                return response(cb, "error", createBadRequestResponse("Chat does not exist!"));
            }

            return response(cb, "chat", createSuccessResponse(await getChatResponse(chats[0])));
        });

        /**
         * Get messages in a chat
         * The `get-messages` endpoint is probably the "proper" one to use.
         * We should probably deprecate this once the clients all use it.
         *
         * TODO: DEPRECATE!
         */
        socket.on(
            "get-chat-messages",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return response(cb, "error", createBadRequestResponse("No chat identifier provided"));

                const chats = await Server().iMessageRepo.getChats({
                    chatGuid: params?.identifier,
                    withSMS: true
                });

                if (!chats || chats.length === 0)
                    return response(cb, "error", createBadRequestResponse("Chat does not exist"));

                const dbParams: DBMessageParams = {
                    chatGuid: chats[0].guid,
                    offset: params?.offset ?? 0,
                    limit: params?.limit ?? 100,
                    after: params?.after,
                    before: params?.before,
                    withChats: params?.withChats ?? false,
                    withAttachments: params?.withAttachments ?? true,
                    withHandle: params?.withHandle ?? true,
                    withSMS: params?.withSMS ?? false,
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

                return response(cb, "chat-messages", createSuccessResponse(results));
            }
        );

        /**
         * Get messages
         */
        socket.on(
            "get-messages",
            async (params, cb): Promise<void> => {
                const after = params?.after;
                if (!params?.after && !params.limit)
                    return response(cb, "error", createBadRequestResponse("No `after` date or `limit` provided!"));

                // See if there is a chat and make sure it exists
                const chatGuid = params?.chatGuid;
                if (chatGuid && chatGuid.length > 0) {
                    const chats = await Server().iMessageRepo.getChats({ chatGuid, withSMS: true });
                    if (!chats || chats.length === 0)
                        return response(cb, "error", createBadRequestResponse("Chat does not exist"));
                }

                const dbParams: DBMessageParams = {
                    chatGuid,
                    offset: params?.offset ?? 0,
                    limit: params?.limit ?? 100,
                    after,
                    before: params?.before,
                    withChats: params?.withChats ?? true, // Default to true
                    withAttachments: params?.withAttachments ?? true, // Default to true
                    withHandle: params?.withHandle ?? true, // Default to true
                    withSMS: params?.withSMS ?? false,
                    sort: params?.sort ?? "ASC" // We want to older messages at the top
                };

                // Add any "where" params
                if (params?.where) dbParams.where = params.where;

                // Get the messages
                const messages = await Server().iMessageRepo.getMessages(dbParams);

                // Do you want the blurhash? Default to true
                const withBlurhash = params?.withBlurhash ?? true;
                const results = [];
                for (const msg of messages) {
                    const msgRes = await getMessageResponse(msg, withBlurhash);
                    results.push(msgRes);
                }

                return response(cb, "messages", createSuccessResponse(results));
            }
        );

        /**
         * Get an attachment by guid
         */
        socket.on(
            "get-attachment",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return response(cb, "error", createBadRequestResponse("No attachment identifier provided"));

                const attachment = await Server().iMessageRepo.getAttachment(params?.identifier, params?.withMessages);
                if (!attachment) return response(cb, "error", createBadRequestResponse("Attachment does not exist"));

                const res = await getAttachmentResponse(attachment, true);
                return response(cb, "attachment", createSuccessResponse(res));
            }
        );

        /**
         * Get an attachment chunk by guid
         */
        socket.on(
            "get-attachment-chunk",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return response(cb, "error", createBadRequestResponse("No attachment identifier provided"));

                // Get the start, with fallbacks to 0
                let start = params?.start ?? 0;
                if (!Number.isInteger(start) || start < 0) start = 0;

                // Pull out the chunk size, falling back to 1024
                const chunkSize = params?.chunkSize ?? 1024;
                const compress = params?.compress ?? false;

                // Get the corresponding attachment
                const attachment = await Server().iMessageRepo.getAttachment(params?.identifier, false);
                if (!attachment) return response(cb, "error", createBadRequestResponse("Attachment does not exist"));

                // Get the fully qualified path
                let fPath = FileSystem.getRealPath(attachment.filePath);

                // Check if the file exists before trying to read it
                if (!fs.existsSync(fPath))
                    return response(cb, "error", createServerErrorResponse("Attachment not downloaded on server"));

                // If the attachment is a caf, let's convert it
                if (attachment.uti === "com.apple.coreaudio-format") {
                    const newPath = `${FileSystem.convertDir}/${attachment.guid}.mp3`;

                    // If the path doesn't exist, let's convert the attachment
                    let failed = false;
                    if (!fs.existsSync(newPath)) {
                        try {
                            Server().log(`Converting attachment, ${attachment.transferName}, to an MP3...`);
                            await FileSystem.convertCafToMp3(attachment, newPath);
                        } catch (ex) {
                            failed = true;
                            Server().log(`Failed to convert CAF to MP3 for attachment, ${attachment.transferName}`);
                            Server().log(ex, "error");
                        }
                    }

                    if (!failed) {
                        // If conversion is successful, we need to modify the attachment a bit
                        attachment.mimeType = "audio/mp3";
                        attachment.filePath = newPath;
                        attachment.transferName = basename(newPath).replace(".caf", ".mp3");

                        // Set the fPath to the newly converted path
                        fPath = newPath;
                    }
                }

                // Check if the file exists before trying to read it
                if (!fs.existsSync(fPath))
                    return response(cb, "error", createServerErrorResponse("Attachment not downloaded on server"));

                // Get data as a Uint8Array
                let data = FileSystem.readFileChunk(fPath, start, chunkSize);
                if (compress) data = Uint8Array.from(zlib.deflateSync(data));

                if (!data) {
                    return response(cb, "attachment-chunk", createNoDataResponse());
                }

                // Convert data to a base64 string
                return response(cb, "attachment-chunk", createSuccessResponse(base64.bytesToBase64(data)));
            }
        );

        /**
         * Get last message in a chat
         */
        socket.on(
            "get-last-chat-message",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return response(cb, "error", createBadRequestResponse("No chat identifier provided"));

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier, withSMS: true });
                if (!chats || chats.length === 0)
                    return response(cb, "error", createBadRequestResponse("Chat does not exist"));

                const messages = await Server().iMessageRepo.getMessages({
                    chatGuid: chats[0].guid,
                    limit: 1
                });
                if (!messages || messages.length === 0)
                    return response(cb, "last-chat-message", createNoDataResponse());

                const result = await getMessageResponse(messages[0]);
                return response(cb, "last-chat-message", createSuccessResponse(result));
            }
        );

        // /**
        //  * Get participants in a chat
        //  */
        socket.on(
            "get-participants",
            async (params, cb): Promise<void> => {
                if (!params?.identifier)
                    return response(cb, "error", createBadRequestResponse("No chat identifier provided"));

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier, withSMS: true });

                if (!chats || chats.length === 0)
                    return response(cb, "error", createBadRequestResponse("Chat does not exist"));

                const handles = [];
                for (const handle of chats[0].participants ?? []) {
                    const handleRes = await getHandleResponse(handle);
                    handles.push(handleRes);
                }

                return response(cb, "participants", createSuccessResponse(handles));
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

                if (!chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided"));

                if ((tempGuid && (!message || message.length === 0)) || (!tempGuid && message))
                    return response(cb, "error", createBadRequestResponse("No temporary GUID provided with message"));

                if (params?.attachment && (!params.attachmentName || !params.attachmentGuid))
                    return response(cb, "error", createBadRequestResponse("No attachment name or GUID provided"));

                try {
                    await ActionHandler.sendMessage(
                        tempGuid,
                        chatGuid,
                        message,
                        params?.attachmentGuid,
                        params?.attachmentName,
                        params?.attachment ? base64.base64ToBytes(params.attachment) : null
                    );

                    return response(cb, "message-sent", createSuccessResponse(null));
                } catch (ex) {
                    return response(cb, "send-message-error", createServerErrorResponse(ex.message));
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

                if (!chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided"));
                if (!tempGuid) return response(cb, "error", createBadRequestResponse("No temporary GUID provided"));

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
                    return response(cb, "error", createBadRequestResponse("No temp GUID provided with message!"));

                // If it's the last chunk, make sure there is a message
                if (!hasMore && attachmentGuid && !params?.attachmentName)
                    return response(cb, "error", createBadRequestResponse("No attachment name provided"));

                // If there are no more chunks, compile, save, and send
                if (!hasMore) {
                    Server().queue.add({
                        type: "send-attachment",
                        data: {
                            tempGuid,
                            chatGuid,
                            message,
                            attachmentGuid,
                            attachmentName: params?.attachmentName,
                            chunks: attachmentGuid ? FileSystem.buildAttachmentChunks(attachmentGuid) : null
                        }
                    });

                    return response(cb, "message-sent", createSuccessResponse(null));
                }

                return response(cb, "message-chunk-saved", createSuccessResponse(null));
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
                    return response(cb, "error", createBadRequestResponse("No participants specified"));

                if (typeof participants === "string") {
                    participants = [participants];
                }

                if (!Array.isArray(participants))
                    return response(cb, "error", createBadRequestResponse("Participant list must be an array"));

                const chatGuid = await ActionHandler.createChat(participants, params?.service || "iMessage");

                try {
                    const newChat = await Server().iMessageRepo.getChats({ chatGuid, withSMS: true });
                    return response(cb, "chat-started", createSuccessResponse(await getChatResponse(newChat[0])));
                } catch (ex) {
                    return response(cb, "start-chat-failed", createServerErrorResponse(ex?.message ?? ex));
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
                    return response(cb, "error", createBadRequestResponse("No chat identifier provided"));
                if (!params?.newName)
                    return response(cb, "error", createBadRequestResponse("No new group name provided"));

                if (Server().blueBubblesServerHelper.helper) {
                    try {
                        await ActionHandler.privateRenameGroupChat(params.identifier, params.newName);

                        const chats = await Server().iMessageRepo.getChats({
                            chatGuid: params.identifier,
                            withSMS: true
                        });
                        return response(cb, "group-renamed", createSuccessResponse(await getChatResponse(chats[0])));
                    } catch (ex) {
                        return response(cb, "rename-group-error", createServerErrorResponse(ex.message));
                    }
                }

                try {
                    await ActionHandler.renameGroupChat(params.identifier, params.newName);

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier, withSMS: true });
                    return response(cb, "group-renamed", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex) {
                    return response(cb, "rename-group-error", createServerErrorResponse(ex.message));
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
                    return response(cb, "error", createBadRequestResponse("No chat identifier provided"));
                if (!params?.address)
                    return response(cb, "error", createBadRequestResponse("No participant address specified"));

                try {
                    const result = await ActionHandler.addParticipant(params.identifier, params.address);
                    if (result.trim() !== "success") return response(cb, "error", createBadRequestResponse(result));

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier, withSMS: true });
                    return response(cb, "participant-added", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex) {
                    return response(cb, "add-participant-error", createServerErrorResponse(ex.message));
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
                    return response(cb, "error", createBadRequestResponse("No chat identifier provided"));
                if (!params?.address)
                    return response(cb, "error", createBadRequestResponse("No participant address specified"));

                try {
                    const result = await ActionHandler.removeParticipant(params.identifier, params.address);
                    if (result.trim() !== "success") return response(cb, "error", createBadRequestResponse(result));

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier, withSMS: true });
                    return response(cb, "participant-removed", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex) {
                    return response(cb, "remove-participant-error", createServerErrorResponse(ex.message));
                }
            }
        );

        // /**
        //  * Send reaction
        //  */
        socket.on(
            "send-reaction",
            async (params, cb): Promise<void> => {
                if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));
                if (!params?.messageGuid || !params?.messageText)
                    return response(cb, "error", createBadRequestResponse("No message provided!"));
                if (!params?.actionMessageGuid || !params?.actionMessageText)
                    return response(cb, "error", createBadRequestResponse("No action message provided!"));
                if (
                    !params?.tapback ||
                    ![
                        "love",
                        "like",
                        "dislike",
                        "laugh",
                        "emphasize",
                        "question",
                        "-love",
                        "-like",
                        "-dislike",
                        "-laugh",
                        "-emphasize",
                        "-question"
                    ].includes(params.tapback)
                )
                    return response(cb, "error", createBadRequestResponse("Invalid tapback descriptor provided!"));

                // If the helper is online, use it to send the tapback
                if (Server().blueBubblesServerHelper.helper) {
                    try {
                        await ActionHandler.togglePrivateTapback(
                            params.chatGuid,
                            params.actionMessageGuid,
                            params.tapback
                        );
                        return response(cb, "tapback-sent", createNoDataResponse());
                    } catch (ex) {
                        return response(cb, "send-tapback-error", createServerErrorResponse(ex.messageText));
                    }
                }

                // Add the reaction to the match queue
                const item = new Queue();
                item.tempGuid = params.messageGuid;
                item.chatGuid = params.chatGuid;
                item.dateCreated = new Date().getTime();
                item.text = params.messageText;
                await Server().repo.queue().manager.save(item);

                try {
                    await ActionHandler.toggleTapback(params.chatGuid, params.actionMessageText, params.tapback);
                    return response(cb, "tapback-sent", createNoDataResponse());
                } catch (ex) {
                    return response(cb, "send-tapback-error", createServerErrorResponse(ex.message));
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
                    response(cb, "contacts", createServerErrorResponse("Contacts repository is disconnected!"));
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

                response(cb, "contacts-from-disk", createSuccessResponse(handles));
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
                    if (fs.existsSync(contactsPath)) {
                        const data = fs.readFileSync(contactsPath).toString("utf-8");
                        response(cb, "contacts-from-vcf", createSuccessResponse(data));
                    } else {
                        response(cb, "contacts-from-vcf", createServerErrorResponse("Failed to export Address Book!"));
                    }
                } catch (ex) {
                    response(cb, "contacts-from-vcf", createServerErrorResponse(ex.message));
                }
            }
        );

        /**
         * Tells all clients that a chat is read
         */
        socket.on("toggle-chat-read-status", (params, cb): void => {
            // Make sure we have all the required data
            if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));
            if (params?.status === null)
                return response(cb, "error", createBadRequestResponse("No chat status provided!"));

            // Send the notification out to all clients
            Server().emitMessage("chat-read-status-changed", {
                chatGuid: params.chatGuid,
                status: params.status
            });

            // Return null so Typescript doesn't yell at us
            return null;
        });

        /**
         * Tells the server to "read a chat"
         */
        socket.on("open-chat", (params, cb): void => {
            // Make sure we have all the required data
            if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));

            // Dispatch it to the queue service
            const item: QueueItem = { type: "open-chat", data: params?.chatGuid };
            Server().queue.add(item);

            // Return null so Typescript doesn't yell at us
            return null;
        });

        /**
         * Tells the server to start typing in a chat
         */
        socket.on(
            "started-typing",
            async (params, cb): Promise<void> => {
                // Make sure we have all the required data
                if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));

                // Dispatch it to the queue service
                try {
                    await ActionHandler.startOrStopTypingInChat(params.chatGuid, true);
                    return response(cb, "started-typing-sent", createSuccessResponse(null));
                } catch {
                    return response(cb, "started-typing-error", createServerErrorResponse("Failed to stop typing"));
                }
            }
        );

        /**
         * Tells the server to stop typing in a chat
         * This will happen automaticaly after 10 seconds,
         * but the client can tell the server to do so manually
         */
        socket.on(
            "stopped-typing",
            async (params, cb): Promise<void> => {
                // Make sure we have all the required data
                if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));

                try {
                    await ActionHandler.startOrStopTypingInChat(params.chatGuid, false);
                    return response(cb, "stopped-typing-sent", createSuccessResponse(null));
                } catch {
                    return response(cb, "stopped-typing-error", createServerErrorResponse("Failed to stop typing!"));
                }
            }
        );
        /**
         * Tells the server to mark a chat as read
         */
        socket.on(
            "mark-chat-read",
            async (params, cb): Promise<void> => {
                // Make sure we have all the required data
                if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));

                try {
                    await ActionHandler.markChatRead(params.chatGuid);
                    return response(cb, "mark-chat-read-sent", createSuccessResponse(null));
                } catch {
                    return response(cb, "mark-chat-read-error", createServerErrorResponse("Failed to mark chat read!"));
                }

                // Return null so Typescript doesn't yell at us
                return null;
            }
        );
        /**
         * Tells the server to stop typing in a chat
         * This will happen automaticaly after 10 seconds,
         * but the client can tell the server to do so manually
         */
        socket.on(
            "update-typing-status",
            async (params, cb): Promise<void> => {
                // Make sure we have all the required data
                if (!params?.chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided!"));

                try {
                    await ActionHandler.updateTypingStatus(params.chatGuid);
                    return response(cb, "update-typing-status-sent", createSuccessResponse(null));
                } catch {
                    return response(
                        cb,
                        "update-typing-status-error",
                        createServerErrorResponse("Failed to update typing status!")
                    );
                }
            }
        );

        socket.on("disconnect", reason => {
            Server().log(`Client ${socket.id} disconnected! Reason: ${reason}`);
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
            this.server = io(Server().repo.getConfig("socket_port") as number, {
                // 5 Minute ping timeout
                pingTimeout: 60000
            });
        }

        this.start();
    }
}
