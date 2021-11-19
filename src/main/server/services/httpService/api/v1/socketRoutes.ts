/* eslint-disable max-len */
import { app } from "electron";
import * as path from "path";
import { basename } from "path";
import * as fs from "fs";
import * as zlib from "zlib";
import * as base64 from "byte-base64";
import * as CryptoJS from "crypto-js";
import { Socket } from "socket.io";

// HTTP libraries
import * as macosVersion from "macos-version";

// Internal libraries
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { isEmpty, isNotEmpty, safeTrim } from "@server/helpers/utils";

// Helpers
import { ChatResponse, HandleResponse, ServerMetadataResponse } from "@server/types";
import { ResponseFormat, ResponseJson } from "@server/services/httpService/api/v1/responses/types";

// Entities
import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import { getMessageResponse } from "@server/databases/imessage/entity/Message";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { DBMessageParams } from "@server/databases/imessage/types";
import { ActionHandler } from "@server/api/v1/apple/actions";
import { QueueItem } from "@server/services/queueService";
import { restartMessages } from "@server/api/v1/apple/scripts";
import { GeneralInterface } from "@server/api/v1/interfaces/generalInterface";
import { MessageInterface } from "@server/api/v1/interfaces/messageInterface";
import { convertAudio } from "@server/databases/imessage/helpers/utils";

import {
    createSuccessResponse,
    createServerErrorResponse,
    createBadRequestResponse,
    createNoDataResponse
} from "./responses";

const osVersion = macosVersion();
const unknownError = "Unknown Error. Check server logs!";

export class SocketRoutes {
    static createRoutes(socket: Socket) {
        const response = (callback: Function | null, channel: string | null, data: ResponseFormat): void => {
            const resData = data as ResponseJson;
            resData.encrypted = false;

            // Only encrypt coms enabled
            const encrypt = Server().repo.getConfig("encrypt_coms") as boolean;
            const passphrase = Server().repo.getConfig("password") as string;

            // Don't encrypt the attachment, it's already encrypted
            if (encrypt) {
                if (typeof resData.data === "string" && channel !== "attachment-chunk") {
                    resData.data = CryptoJS.AES.encrypt(resData.data, passphrase).toString();
                    resData.encrypted = true;
                } else if (channel !== "attachment-chunk") {
                    resData.data = CryptoJS.AES.encrypt(JSON.stringify(resData.data), passphrase).toString();
                    resData.encrypted = true;
                }
            }

            if (callback) callback(resData);
            else socket.emit(channel, resData);

            if (resData.error) Server().log(resData.error.message, "error");
        };

        /**
         * Return information about the server
         */
        socket.on("get-server-metadata", (_, cb): void => {
            const meta: ServerMetadataResponse = {
                os_version: osVersion,
                server_version: app.getVersion(),
                private_api: Server().repo.getConfig("enable_private_api") as boolean,
                proxy_service: Server().repo.getConfig("proxy_service") as string,
                helper_connected: !!Server().privateApiHelper?.helper
            };

            return response(cb, "server-metadata", createSuccessResponse(meta, "Successfully fetched metadata"));
        });

        /**
         * Save a VCF file
         */
        socket.on(
            "save-vcf",
            async (params, cb): Promise<void> => {
                // Make sure we have VCF data
                if (!params?.vcf) return response(cb, "error", createBadRequestResponse("No VCF data provided!"));

                FileSystem.saveVCF(params.vcf);
                return response(cb, "save-vcf", createSuccessResponse(null, "Successfully saved VCF"));
            }
        );

        /**
         * Save a VCF file
         */
        socket.on(
            "get-vcf",
            async (_, cb): Promise<void> => {
                const vcf = FileSystem.getVCF();
                return response(cb, "save-vcf", createSuccessResponse(vcf, "Successfully retrieved VCF"));
            }
        );

        /**
         * Change proxy service
         */
        socket.on(
            "change-proxy-service",
            async (params, cb): Promise<void> => {
                // Make sure we have a service
                if (!params?.service)
                    return response(cb, "error", createBadRequestResponse("No service name provided!"));

                // Make sure the service is one that we can handle
                const serviceOpts = ["Ngrok", "Cloudflare", "LocalTunnel", "Dynamic DNS"];
                if (!serviceOpts.includes(params.service))
                    return response(
                        cb,
                        "error",
                        createBadRequestResponse(`Service name must be one of the following: ${serviceOpts.join(", ")}`)
                    );

                // If the service is dynamic DNS, make sure we have an address
                if (params.service === "Dynamic DNS" && !params?.address)
                    return response(cb, "error", createBadRequestResponse("No Dynamic DNS address provided!"));

                // Send the response back before restarting
                const res = response(
                    cb,
                    "change-proxy-service",
                    createSuccessResponse(null, "Successfully set new proxy service!")
                );

                // Now, set the new proxy service
                await Server().stopProxyServices();
                await Server().repo.setConfig("proxy_service", params.service);

                // If it's a dyn dns, set the address
                if (params.service === "Dynamic DNS") {
                    let addr = params.address;
                    if (!addr.startsWith("http")) {
                        addr = `http://${addr}`;
                    }

                    await Server().repo.setConfig("server_address", addr);
                }

                // Restart the proxy services
                await Server().restartProxyServices();
                return res;
            }
        );

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

                await GeneralInterface.addFcmDevice(params?.deviceName, params?.deviceId);
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
            const withLastMessage = params?.withLastMessage ?? false;
            const withParticipants = !withLastMessage && (params?.withParticipants ?? true);
            let sort = params?.sort ?? "";

            // Validate sort param
            if (typeof sort !== "string") {
                return response(cb, "error", createBadRequestResponse("Sort parameter must be a string (get-chats)!"));
            }

            sort = sort.toLowerCase();
            const validSorts = ["lastmessage"];
            if (!validSorts.includes(sort)) {
                sort = null;
            }

            const chats = await Server().iMessageRepo.getChats({
                withParticipants,
                withLastMessage,
                withArchived: params?.withArchived ?? false,
                limit: params?.limit ?? null,
                offset: params?.offset ?? 0
            });

            // If the query is with the last message, it makes the participants list 1 for each chat
            // We need to fetch all the chats with their participants, then cache the participants
            // so we can merge the participant list with the chats
            const chatCache: { [key: string]: Handle[] } = {};
            const tmpChats = await Server().iMessageRepo.getChats({
                withParticipants: true,
                withArchived: params?.withArchived ?? false
            });

            for (const chat of tmpChats) {
                chatCache[chat.guid] = chat.participants;
            }

            const results = [];
            for (const chat of chats ?? []) {
                if (chat.guid.startsWith("urn:")) continue;
                const chatRes = await getChatResponse(chat);

                // Insert the cached participants from the original request
                if (Object.keys(chatCache).includes(chat.guid)) {
                    chatRes.participants = await Promise.all(
                        chatCache[chat.guid].map(
                            async (e): Promise<HandleResponse> => {
                                const test = await getHandleResponse(e);
                                return test;
                            }
                        )
                    );
                }

                if (withLastMessage) {
                    // Set the last message, if applicable
                    if (isNotEmpty(chatRes.messages)) {
                        [chatRes.lastMessage] = chatRes.messages;

                        // Remove the last message from the result
                        delete chatRes.messages;
                    }
                }

                results.push(chatRes);
            }

            // If we have a sort parameter, handle the cases
            if (sort) {
                if (sort === "lastmessage" && withLastMessage) {
                    results.sort((a: ChatResponse, b: ChatResponse) => {
                        const d1 = a.lastMessage?.dateCreated ?? 0;
                        const d2 = b.lastMessage?.dateCreated ?? 0;
                        if (d1 > d2) return -1;
                        if (d1 < d2) return 1;
                        return 0;
                    });
                }
            }

            return response(cb, "chats", createSuccessResponse(results));
        });

        /**
         * Get single chat
         */
        socket.on("get-chat", async (params, cb) => {
            const chatGuid = params?.chatGuid;
            if (!chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided"));

            const chats = await Server().iMessageRepo.getChats({
                chatGuid,
                withParticipants: params?.withParticipants ?? true
            });
            if (isEmpty(chats)) {
                return response(cb, "error", createBadRequestResponse("Chat does not exist (get-chat)!"));
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
                    chatGuid: params?.identifier
                });

                if (isEmpty(chats))
                    return response(cb, "error", createBadRequestResponse("Chat does not exist (get-chat-messages)"));

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
                const results = [];
                for (const msg of messages) {
                    const msgRes = await getMessageResponse(msg);
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
                if (isNotEmpty(chatGuid)) {
                    const chats = await Server().iMessageRepo.getChats({ chatGuid });
                    if (isEmpty(chats))
                        return response(cb, "error", createBadRequestResponse("Chat does not exist (get-messages)"));
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
                    sort: params?.sort ?? "ASC" // We want to older messages at the top
                };

                // Add any "where" params
                if (params?.where) dbParams.where = params.where;

                // Get the messages
                const messages = await Server().iMessageRepo.getMessages(dbParams);

                // Handle fetching the chat participants with the messages (if requested)
                const withChatParticipants = params?.withChatParticipants ?? false;
                const chatCache: { [key: string]: Handle[] } = {};
                if (withChatParticipants) {
                    const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
                    for (const i of chats) {
                        chatCache[i.guid] = i.participants;
                    }
                }

                const results = [];
                for (const msg of messages) {
                    // Insert in the participants from the cache
                    if (withChatParticipants) {
                        for (const chat of msg.chats) {
                            if (Object.keys(chatCache).includes(chat.guid)) {
                                chat.participants = chatCache[chat.guid];
                            }
                        }
                    }

                    const msgRes = await getMessageResponse(msg);
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
                    fPath = await convertAudio(attachment);
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

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier });
                if (isEmpty(chats))
                    return response(
                        cb,
                        "error",
                        createBadRequestResponse("Chat does not exist (get-last-chat-message)")
                    );

                const messages = await Server().iMessageRepo.getMessages({
                    chatGuid: chats[0].guid,
                    limit: 1
                });
                if (isEmpty(messages)) return response(cb, "last-chat-message", createNoDataResponse());

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

                const chats = await Server().iMessageRepo.getChats({ chatGuid: params?.identifier });

                if (isEmpty(chats))
                    return response(cb, "error", createBadRequestResponse("Chat does not exist (get-participants)"));

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
                let tempGuid = params?.tempGuid;
                const chatGuid = params?.guid;
                const message = params?.message;

                // Make sure a chat GUID is provided
                if (!chatGuid) return response(cb, "error", createBadRequestResponse("No chat GUID provided"));

                // Make sure the chat exists (if group chat)
                if (chatGuid.includes(";+;")) {
                    const chats = await Server().iMessageRepo.getChats({ chatGuid });
                    if (isEmpty(chats))
                        return response(
                            cb,
                            "error",
                            createBadRequestResponse(`Chat with GUID, "${chatGuid}" does not exist`)
                        );
                }

                // Make sure we have a temp GUID, for matching
                if ((tempGuid && isEmpty(message)) || (!tempGuid && message))
                    return response(cb, "error", createBadRequestResponse("No temporary GUID provided with message"));

                // Make sure that if we have an attachment, there is also a guid and name
                if (params?.attachment && (!params.attachmentName || !params.attachmentGuid))
                    return response(cb, "error", createBadRequestResponse("No attachment name or GUID provided"));

                if (typeof tempGuid === "number") {
                    tempGuid = String(tempGuid);
                }

                // Debug logging
                if (isNotEmpty(tempGuid)) {
                    Server().log(`Attempting to send message using Temp GUID: ${tempGuid}`, "debug");
                }

                // Make sure the message isn't already in the queue
                if (Server().httpService.sendCache.find(tempGuid)) {
                    return response(
                        cb,
                        "error",
                        createBadRequestResponse(`Message is already queued to be sent (Temp GUID: ${tempGuid})!`)
                    );
                }

                // Add to send cache
                Server().httpService.sendCache.add(tempGuid);

                try {
                    // Send the message
                    const sentMessage = await MessageInterface.sendMessageSync(
                        chatGuid,
                        message,
                        "apple-script",
                        null,
                        null,
                        null,
                        tempGuid
                    );

                    Server().httpService.sendCache.remove(tempGuid);
                    return response(cb, "message-sent", createSuccessResponse(await getMessageResponse(sentMessage)));
                } catch (ex: any) {
                    Server().httpService.sendCache.remove(tempGuid);
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

                // Make sure the message isn't already in the queue
                if (Server().httpService.sendCache.find(tempGuid)) {
                    return response(cb, "error", createBadRequestResponse("Attachment is already queued to be sent!"));
                }

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
                if (!hasMore && !tempGuid && isEmpty(message))
                    return response(cb, "error", createBadRequestResponse("No temp GUID provided with message!"));

                // If it's the last chunk, make sure there an attachment name
                if (!hasMore && attachmentGuid && !params?.attachmentName)
                    return response(cb, "error", createBadRequestResponse("No attachment name provided"));

                // If there are no more chunks, compile, save, and send
                if (!hasMore) {
                    // Make sure the chat exists before we send the response
                    if (chatGuid.includes(";+;")) {
                        const chats = await Server().iMessageRepo.getChats({ chatGuid });
                        if (isEmpty(chats))
                            return response(
                                cb,
                                "error",
                                createBadRequestResponse(`Chat with GUID, "${chatGuid}" does not exist`)
                            );
                    }

                    // Add the image to the send cache
                    Server().httpService.sendCache.add(tempGuid);

                    // Save the attachment parts to a file
                    const attachmentPath = FileSystem.buildAttachmentChunks(attachmentGuid, params?.attachmentName);

                    // Add the action to the queue
                    Server().queue.add({
                        type: "send-attachment",
                        data: {
                            tempGuid,
                            chatGuid,
                            message,
                            attachmentGuid,
                            attachmentName: params?.attachmentName,
                            attachmentPath
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

                if (isEmpty(participants)) {
                    return response(cb, "error", createBadRequestResponse("No participants specified"));
                }

                if (typeof participants === "string") {
                    participants = [participants];
                }

                if (!Array.isArray(participants)) {
                    return response(cb, "error", createBadRequestResponse("Participant list must be an array"));
                }

                let chatGuid;

                try {
                    // First, try to create the chat using our "normal" method
                    chatGuid = await ActionHandler.createUniversalChat(
                        participants,
                        params?.service ?? "iMessage",
                        params?.message,
                        params?.tempGuid
                    );
                } catch (ex: any) {
                    // If there was a failure, and there is only 1 participant, and we have a message, try to fallback
                    if (participants.length === 1 && isNotEmpty(params?.message) && isNotEmpty(params?.tempGuid)) {
                        Server().log("Universal create chat failed. Attempting single chat creation.", "debug");

                        try {
                            chatGuid = await ActionHandler.createSingleChat(
                                participants[0],
                                params?.service ?? "iMessage",
                                params?.message,
                                params?.tempGuid
                            );
                        } catch (ex2: any) {
                            // If the fallback fails, return that error
                            return response(cb, "error", createBadRequestResponse(ex2?.message ?? ex2 ?? unknownError));
                        }
                    } else {
                        // If it failed and didn't meet our fallback criteria, return the error as-is
                        return response(cb, "error", createBadRequestResponse(ex?.message ?? ex ?? unknownError));
                    }
                }

                // Make sure we have a chat GUID
                if (isEmpty(chatGuid)) {
                    return response(cb, "error", createBadRequestResponse("Failed to create chat! Check server logs!"));
                }

                try {
                    const newChat = await Server().iMessageRepo.getChats({ chatGuid });
                    return response(cb, "chat-started", createSuccessResponse(await getChatResponse(newChat[0])));
                } catch (ex: any) {
                    let err = ex?.message ?? ex ?? unknownError;

                    // If it's a ROWID error, we want to handle it specifically
                    if (err.toLowerCase().includes("rowid")) {
                        err =
                            `iMessage/iCloud is not configured on your macOS device! ` +
                            `Configure it, then rescan your QRCode`;
                    }

                    return response(cb, "start-chat-failed", createServerErrorResponse(err));
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

                if (Server().privateApiHelper?.helper) {
                    try {
                        await ActionHandler.privateRenameGroupChat(params.identifier, params.newName);

                        const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                        return response(cb, "group-renamed", createSuccessResponse(await getChatResponse(chats[0])));
                    } catch (ex: any) {
                        return response(cb, "rename-group-error", createServerErrorResponse(ex.message));
                    }
                }

                try {
                    await ActionHandler.renameGroupChat(params.identifier, params.newName);

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                    return response(cb, "group-renamed", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex: any) {
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
                    if (safeTrim(result) !== "success") return response(cb, "error", createBadRequestResponse(result));

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                    return response(cb, "participant-added", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex: any) {
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
                    if (safeTrim(result) !== "success") return response(cb, "error", createBadRequestResponse(result));

                    const chats = await Server().iMessageRepo.getChats({ chatGuid: params.identifier });
                    return response(cb, "participant-removed", createSuccessResponse(await getChatResponse(chats[0])));
                } catch (ex: any) {
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
                // Make sure we have a temp GUID, for matching
                const tempGuid = params?.tempGuid || params?.messageGuid;
                if (isEmpty(tempGuid))
                    return response(cb, "error", createBadRequestResponse("No temporary GUID provided with message!"));
                if (!tempGuid || !params?.messageText)
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

                // Fetch the message we are reacting to
                const message = await Server().iMessageRepo.getMessage(params.actionMessageGuid, false, true);
                if (!message) {
                    return response(cb, "error", createBadRequestResponse("Selected message does not exist!"));
                }

                // If the helper is online, use it to send the tapback
                if (Server().privateApiHelper?.helper) {
                    try {
                        const sentMessage = await MessageInterface.sendReaction(
                            params.chatGuid,
                            message,
                            params.tapback,
                            tempGuid
                        );

                        return response(
                            cb,
                            "tapback-sent",
                            createSuccessResponse(await getMessageResponse(sentMessage), "Successfully sent reaction!")
                        );
                    } catch (ex: any) {
                        return response(cb, "send-tapback-error", createServerErrorResponse(ex.message));
                    }
                }

                return response(
                    cb,
                    "send-tapback-error",
                    createServerErrorResponse("iMessage Private API Helper is not connected!")
                );
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

                const handles = params.map((e: any) => (typeof e === "string" ? { address: e } : e));
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
                } catch (ex: any) {
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

        /**
         * Tells the server to restart iMessages
         */
        socket.on(
            "restart-messages-app",
            async (_, cb): Promise<void> => {
                await FileSystem.executeAppleScript(restartMessages());
                return response(cb, "restart-messages-app", createSuccessResponse(null));
            }
        );

        /**
         * Tells the server to restart the Private API helper
         */
        socket.on(
            "restart-private-api",
            async (_, cb): Promise<void> => {
                Server().privateApiHelper.start();
                return response(cb, "restart-private-api-success", createSuccessResponse(null));
            }
        );

        /**
         * Checks for a serer update
         */
        socket.on(
            "check-for-server-update",
            async (_, cb): Promise<void> => {
                return response(cb, "save-vcf", createSuccessResponse(await GeneralInterface.checkForUpdate()));
            }
        );

        socket.on("disconnect", reason => {
            Server().log(`Client ${socket.id} disconnected! Reason: ${reason}`);
        });
    }
}
