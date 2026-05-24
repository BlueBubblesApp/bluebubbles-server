import { Server } from "@server";
import * as fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { MessagePromise } from "@server/managers/outgoingMessageManager/messagePromise";
import { Message } from "@server/databases/imessage/entity/Message";
import { checkPrivateApiStatus, isEmpty, isNotEmpty, resultAwaiter } from "@server/helpers/utils";
import { isMinMonterey, isMinSequoia, isMinVentura } from "@server/env";
import { negativeReactionTextMap, reactionTextMap } from "@server/api/apple/mappings";
import { invisibleMediaChar } from "@server/api/http/constants";
import { ActionHandler } from "@server/api/apple/actions";
import { rimrafSync } from "rimraf";
import { hasTextFormatting, validateTextFormatting } from "@server/utils/TextFormattingUtils";
import type {
    SendMessageParams,
    SendAttachmentParams,
    SendMessagePrivateApiParams,
    SendReactionParams,
    UnsendMessageParams,
    EditMessageParams,
    SendAttachmentPrivateApiParams,
    SendMultipartTextParams,
    SendPollParams,
    ReadPollParams,
    PollData,
    PollResponse
} from "@server/api/types";
import { Chat } from "@server/databases/imessage/entity/Chat";
import path from "path";
import { DBWhereItem } from "@server/databases/imessage/types";

export class MessageInterface {
    static possibleReactions: string[] = [
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
    ];

    private static getArchiveObject(objects: any[], value: any): any {
        if (typeof value?.UID !== "number") return value;
        return objects?.[value.UID];
    }

    private static getArchiveDictionaryValue(objects: any[], dictionary: any, key: string): any {
        if (dictionary == null) return undefined;
        if (Object.prototype.hasOwnProperty.call(dictionary, key)) return dictionary[key];

        const keys = dictionary["NS.keys"];
        const values = dictionary["NS.objects"];
        if (!Array.isArray(keys) || !Array.isArray(values)) return undefined;

        for (let i = 0; i < keys.length; i++) {
            if (MessageInterface.getArchiveObject(objects, keys[i]) === key) return values[i];
        }

        return undefined;
    }

    private static bufferFromArchiveData(rawData: any): Buffer | null {
        if (Buffer.isBuffer(rawData)) {
            return rawData;
        } else if (rawData instanceof Uint8Array) {
            return Buffer.from(rawData);
        } else if (Array.isArray(rawData?.data)) {
            return Buffer.from(rawData.data);
        }

        return null;
    }

    private static getArchiveString(objects: any[], value: any): string | null {
        const raw = MessageInterface.getArchiveObject(objects, value);
        if (typeof raw === "string") return raw;

        const relative = MessageInterface.getArchiveObject(objects, raw?.["NS.relative"]);
        const base = MessageInterface.getArchiveObject(objects, raw?.["NS.base"]);
        if (typeof relative === "string") {
            const prefix = typeof base === "string" && base !== "$null" ? base : "";
            return `${prefix}${relative}`;
        }

        return null;
    }

    private static getArchiveUuid(objects: any[], value: any): string | null {
        const raw = MessageInterface.getArchiveObject(objects, value);
        if (typeof raw === "string") return raw;

        const uuidBytes = MessageInterface.getArchiveObject(objects, raw?.["NS.uuidbytes"]);
        const buffer = MessageInterface.bufferFromArchiveData(uuidBytes);
        if (!buffer || buffer.length !== 16) return null;

        const hex = Array.from(buffer, byte => byte.toString(16).padStart(2, "0")).join("").toUpperCase();
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }

    private static parsePollDefinition(rawData: any): any | null {
        let buffer = MessageInterface.bufferFromArchiveData(rawData);

        if (!buffer && typeof rawData === "string" && rawData.startsWith("data:")) {
            return MessageInterface.parsePollDefinitionUrl(rawData);
        } else if (typeof rawData === "string") {
            try {
                return JSON.parse(rawData);
            } catch {
                buffer = Buffer.from(rawData, "base64");
            }
        }

        if (!buffer) return null;

        try {
            return JSON.parse(buffer.toString("utf8"));
        } catch {
            return null;
        }
    }

    private static parsePollDefinitionUrl(rawUrl: string | null): any | null {
        if (typeof rawUrl !== "string" || !rawUrl.startsWith("data:")) return null;

        if (rawUrl.startsWith("data:application/octet-stream;base64,")) {
            return MessageInterface.parsePollDefinition(rawUrl.replace("data:application/octet-stream;base64,", ""));
        }

        const commaIndex = rawUrl.indexOf(",");
        if (commaIndex < 0) return null;

        const queryIndex = rawUrl.indexOf("?", commaIndex + 1);
        const encoded = rawUrl.slice(commaIndex + 1, queryIndex < 0 ? undefined : queryIndex);
        try {
            return JSON.parse(decodeURIComponent(encoded));
        } catch {
            try {
                return JSON.parse(encoded);
            } catch {
                try {
                    return JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
                } catch {
                    return null;
                }
            }
        }
    }

    private static readPollFromPayload(message: Message): PollData | null {
        for (const payload of message?.payloadData ?? []) {
            const objects = payload?.$objects;
            if (!Array.isArray(objects)) continue;

            const root = MessageInterface.getArchiveObject(objects, payload?.$top?.root);
            const pollDefinitionData = MessageInterface.getArchiveObject(
                objects,
                MessageInterface.getArchiveDictionaryValue(objects, root, "IMPLUGIN_DATA_KEY")
            );
            const pollDefinitionUrl = MessageInterface.getArchiveString(
                objects,
                MessageInterface.getArchiveDictionaryValue(objects, root, "URL")
            );
            const versionedPollDefinition =
                MessageInterface.parsePollDefinition(pollDefinitionData) ??
                MessageInterface.parsePollDefinitionUrl(pollDefinitionUrl);
            const pollDefinition = versionedPollDefinition?.item ?? versionedPollDefinition?.pollDefinition;
            const rawOptions = pollDefinition?.orderedPollOptions;
            if (!Array.isArray(rawOptions)) continue;

            const options = rawOptions.map(option => ({
                optionIdentifier: option?.optionIdentifier ?? null,
                creatorHandle: option?.creatorHandle ?? null,
                text: option?.text ?? null,
                attributedText: option?.attributedText ?? null,
                canBeEdited: option?.canBeEdited
            }));

            return {
                messageGuid: message.guid,
                title: pollDefinition?.title ?? null,
                options,
                responses: [],
                optionCount: options.length,
                bundleIdentifier: message.balloonBundleId ?? null,
                pluginSessionGuid:
                    MessageInterface.getArchiveObject(
                        objects,
                        MessageInterface.getArchiveDictionaryValue(objects, root, "IMPLUGIN_PLUGINSESSIONGUID_KEY")
                    ) ??
                    MessageInterface.getArchiveUuid(
                        objects,
                        MessageInterface.getArchiveDictionaryValue(objects, root, "sessionIdentifier")
                    ) ??
                    null
            };
        }

        return null;
    }

    private static readPollResponsesFromPayload(message: Message): PollResponse[] {
        const responses: PollResponse[] = [];

        for (const payload of message?.payloadData ?? []) {
            const objects = payload?.$objects;
            if (!Array.isArray(objects)) continue;

            const root = MessageInterface.getArchiveObject(objects, payload?.$top?.root);
            const pollResponseUrl = MessageInterface.getArchiveString(
                objects,
                MessageInterface.getArchiveDictionaryValue(objects, root, "URL")
            );
            const versionedResponse = MessageInterface.parsePollDefinitionUrl(pollResponseUrl);
            const votes = versionedResponse?.item?.votes;
            if (!Array.isArray(votes)) continue;

            const byHandle = new Map<string | null, string[]>();
            for (const vote of votes) {
                const handle = vote?.participantHandle ?? null;
                const optionIdentifier = vote?.voteOptionIdentifier ?? null;
                if (!optionIdentifier) continue;

                const optionIdentifiers = byHandle.get(handle) ?? [];
                if (!optionIdentifiers.includes(optionIdentifier)) {
                    optionIdentifiers.push(optionIdentifier);
                }
                byHandle.set(handle, optionIdentifiers);
            }

            for (const [handle, optionIdentifiers] of byHandle.entries()) {
                responses.push({ handle, optionIdentifiers });
            }
        }

        return responses;
    }

    private static async readPollResponsesForMessage(chatGuid: string, messageGuid: string): Promise<PollResponse[]> {
        const [messages] = await Server().iMessageRepo.getMessages({
            chatGuid,
            withAttachments: false,
            sort: "ASC",
            orderBy: "message.dateCreated",
            where: [
                {
                    statement: "(message.associatedMessageGuid = :messageGuid OR message.replyToGuid = :messageGuid)",
                    args: { messageGuid }
                },
                {
                    statement: "message.payloadData IS NOT NULL",
                    args: null
                }
            ]
        });

        const byHandle = new Map<string | null, string[]>();
        for (const message of messages) {
            for (const response of MessageInterface.readPollResponsesFromPayload(message)) {
                byHandle.set(response.handle, response.optionIdentifiers);
            }
        }

        return Array.from(byHandle.entries()).map(([handle, optionIdentifiers]) => ({
            handle,
            optionIdentifiers
        }));
    }

    private static async mergePollResponses(chatGuid: string, messageGuid: string, poll: PollData): Promise<PollData> {
        const responses = await MessageInterface.readPollResponsesForMessage(chatGuid, messageGuid);
        return {
            ...poll,
            responses
        };
    }

    /**
     * Sends a message by executing the sendMessage AppleScript
     *
     * @param chatGuid The GUID for the chat
     * @param message The message to send
     * @param attachmentName The name of the attachment to send (optional)
     * @param attachment The bytes (buffer) for the attachment
     *
     * @returns The command line response
     */
    static async sendMessageSync({
        chatGuid,
        message,
        method = "apple-script",
        attributedBody = null,
        textFormatting = null,
        subject = null,
        effectId = null,
        selectedMessageGuid = null,
        tempGuid = null,
        partIndex = 0,
        ddScan = false
    }: SendMessageParams): Promise<Message> {
        if (!chatGuid) throw new Error("No chat GUID provided");

        Server().log(`Sending message "${message}" to ${chatGuid}`, "debug");

        if (hasTextFormatting(textFormatting)) {
            if (attributedBody) {
                throw new Error("Use either textFormatting or attributedBody, not both");
            }

            if (method !== "private-api") {
                throw new Error("Text formatting requires the Private API send method");
            }

            if (!isMinSequoia) {
                throw new Error("Text formatting is only supported on macOS Sequoia (15) and newer");
            }

            validateTextFormatting(textFormatting, message ?? "");
        }

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        const awaiter = new MessagePromise({
            chatGuid,
            text: message,
            isAttachment: false,
            sentAt: now,
            subject,
            tempGuid
        });

        // Add the promise to the manager
        Server().log(`Adding await for chat: "${chatGuid}"; text: ${awaiter.text}; tempGuid: ${tempGuid ?? "N/A"}`);
        Server().messageManager.add(awaiter);

        // Remove the chat from the typing cache
        if (Server().typingCache.includes(chatGuid)) {
            Server().typingCache = Server().typingCache.filter(c => c !== chatGuid);

            try {
                // Try to stop typing for that chat. Don't await so we don't block the message
                await Server().privateApi.chat.stopTyping(chatGuid);
            } catch {
                // Do nothing
            }
        }

        // Try to send the iMessage
        let sentMessage = null;
        if (method === "apple-script") {
            // Attempt to send the message
            await ActionHandler.sendMessage(chatGuid, message ?? "", null);
            sentMessage = await awaiter.promise;
        } else if (method === "private-api") {
            sentMessage = await MessageInterface.sendMessagePrivateApi({
                chatGuid,
                message,
                attributedBody,
                textFormatting,
                subject,
                effectId,
                selectedMessageGuid,
                partIndex,
                ddScan
            });
        } else {
            throw new Error(`Invalid send method: ${method}`);
        }

        return sentMessage;
    }

    /**
     * Sends a message by executing the sendMessage AppleScript
     *
     * @param chatGuid The GUID for the chat
     * @param message The message to send
     * @param attachmentName The name of the attachment to send (optional)
     * @param attachment The bytes (buffer) for the attachment
     *
     * @returns The command line response
     */
    static async sendAttachmentSync({
        chatGuid,
        attachmentPath,
        attachmentName = null,
        attachmentGuid = null,
        method = "apple-script",
        attributedBody = null,
        subject = null,
        effectId = null,
        selectedMessageGuid = null,
        partIndex = 0,
        isAudioMessage = false
    }: SendAttachmentParams): Promise<Message> {
        if (!chatGuid) throw new Error("No chat GUID provided");

        // Copy the attachment to a more permanent storage
        const newPath = FileSystem.copyAttachment(attachmentPath, attachmentName, method);

        Server().log(`Sending attachment "${attachmentName}" to ${chatGuid}`, "debug");

        // Make sure messages is open
        if (method === "apple-script") {
            await FileSystem.startMessages();
        }

        // Since we convert mp3s to cafs we need to correct the name for the awaiter
        let aName = attachmentName;
        if (aName !== null && aName.endsWith(".mp3") && isAudioMessage) {
            aName = `${aName.substring(0, aName.length - 4)}.caf`;
        }

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        const awaiter = new MessagePromise({
            chatGuid: chatGuid,
            text: aName,
            isAttachment: true,
            sentAt: now,
            tempGuid: attachmentGuid
        });

        // Add the promise to the manager
        Server().log(
            `Adding await for chat: "${chatGuid}"; attachment: ${aName}; tempGuid: ${attachmentGuid ?? "N/A"}`
        );
        Server().messageManager.add(awaiter);

        let sentMessage = null;
        if (method === "apple-script") {
            // Attempt to send the attachment
            await ActionHandler.sendMessage(chatGuid, "", newPath, isAudioMessage);
            sentMessage = await awaiter.promise;
        } else if (method === "private-api") {
            sentMessage = await MessageInterface.sendAttachmentPrivateApi({
                chatGuid,
                filePath: newPath,
                attributedBody,
                subject,
                effectId,
                selectedMessageGuid,
                partIndex,
                isAudioMessage
            });

            try {
                // Wait for the promise so that we can confirm the message was sent.
                // Wrapped in a try/catch because if the private API returned a sentMessage,
                // we know it sent, and maybe it just took a while (longer than the timeout).
                // Only wait for the promise if it's not sent yet.
                if (sentMessage && !sentMessage.isSent) {
                    sentMessage = await awaiter.promise;
                }
            } catch (e) {
                if (sentMessage) {
                    Server().log("Attachment sent via Private API, but message match failed", "debug");
                } else {
                    throw e;
                }
            }
        } else {
            throw new Error(`Invalid send method: ${method}`);
        }

        // Delete the attachment.
        // Only if below Monterey. On Monterey, we store attachments
        // within the iMessage App Support directory. When AppleScript sees this
        // it _does not_ copy the attachment to a permanent location.
        // This means that if we delete the attachment, it won't be downloadable anymore.
        if (!isMinMonterey && method === "apple-script") {
            fs.unlink(newPath, _ => null);
        }

        return sentMessage;
    }

    static async sendMessagePrivateApi({
        chatGuid,
        message,
        attributedBody = null,
        textFormatting = null,
        subject = null,
        effectId = null,
        selectedMessageGuid = null,
        partIndex = 0,
        ddScan = false
    }: SendMessagePrivateApiParams) {
        checkPrivateApiStatus();
        const result = await Server().privateApi.message.send(
            chatGuid,
            message,
            attributedBody ?? null,
            textFormatting ?? null,
            subject ?? null,
            effectId ?? null,
            selectedMessageGuid ?? null,
            partIndex ?? 0,
            ddScan ?? false
        );

        if (!result?.identifier) {
            throw new Error("Failed to send message!");
        }

        const maxWaitMs = 60000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(result.identifier, true, false);
            }
        });

        if (!retMessage) {
            throw new Error(`Failed to send message! Message not found in database after ${maxWaitMs / 1000} seconds!`);
        }

        return retMessage;
    }

    static async sendAttachmentPrivateApi({
        chatGuid,
        filePath,
        attributedBody = null,
        subject = null,
        effectId = null,
        selectedMessageGuid = null,
        partIndex = 0,
        isAudioMessage = false
    }: SendAttachmentPrivateApiParams): Promise<Message> {
        checkPrivateApiStatus();

        if (filePath.endsWith(".mp3") && isAudioMessage) {
            try {
                const newPath = `${filePath.substring(0, filePath.length - 4)}.caf`;
                await FileSystem.convertMp3ToCaf(filePath, newPath);
                filePath = newPath;
            } catch (ex) {
                Server().log("Failed to convert MP3 to CAF!", "warn");
            }
        }

        const result = await Server().privateApi.attachment.send({
            chatGuid,
            filePath,
            attributedBody,
            subject,
            effectId,
            selectedMessageGuid,
            partIndex,
            isAudioMessage
        });

        if (!result?.identifier) {
            throw new Error("Failed to send attachment!");
        }

        const maxWaitMs = 60000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(result.identifier, true, false);
            }
        });

        // Check if the name changed
        if (!retMessage) {
            throw new Error(
                `Failed to send attachment! Attachment not found in database after ${maxWaitMs / 1000} seconds!`
            );
        }

        return retMessage;
    }

    static async unsendMessage({ chatGuid, messageGuid, partIndex = 0 }: UnsendMessageParams) {
        checkPrivateApiStatus();
        if (!isMinVentura) throw new Error("Unsend message is only supported on macOS Ventura and newer!");

        const msg = await Server().iMessageRepo.getMessage(messageGuid, false, false);
        const currentEditDate = msg?.dateEdited ?? 0;
        await Server().privateApi.message.unsend({ chatGuid, messageGuid, partIndex: partIndex ?? 0 });

        const maxWaitMs = 30000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(messageGuid, true, false);
            },
            // Keep looping if the edit date is less than or equal to the original edit date.
            extraLoopCondition: data => {
                return (data?.dateEdited ?? 0) <= currentEditDate;
            }
        });

        // Check if the name changed
        if (!retMessage) {
            throw new Error(`Failed to unsend message! Message not edited (unsent) after ${maxWaitMs / 1000} seconds!`);
        }

        return retMessage;
    }

    static async editMessage({
        chatGuid,
        messageGuid,
        editedMessage,
        backwardsCompatMessage,
        partIndex = 0
    }: EditMessageParams) {
        checkPrivateApiStatus();
        if (!isMinVentura) throw new Error("Unsend message is only supported on macOS Ventura and newer!");

        const msg = await Server().iMessageRepo.getMessage(messageGuid, false, false);
        const currentEditDate = msg?.dateEdited ?? 0;
        await Server().privateApi.message.edit({
            chatGuid,
            messageGuid,
            editedMessage,
            backwardsCompatMessage,
            partIndex: partIndex ?? 0
        });

        const maxWaitMs = 30000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(messageGuid, true, false);
            },
            // Keep looping if the edit date is less than or equal to the original edit date.
            extraLoopCondition: data => {
                return (data?.dateEdited ?? 0) <= currentEditDate;
            }
        });

        // Check if the name changed
        if (!retMessage) {
            throw new Error(`Failed to edit message! Message not edited after ${maxWaitMs / 1000} seconds!`);
        }

        return retMessage;
    }

    static async sendReaction({
        chatGuid,
        message,
        reaction,
        tempGuid = null,
        partIndex = 0
    }: SendReactionParams): Promise<Message> {
        checkPrivateApiStatus();

        // Rebuild the selected message text to make it what the reaction text
        // would be in the database
        const prefix = (reaction as string).startsWith("-")
            ? negativeReactionTextMap[reaction as string]
            : reactionTextMap[reaction as string];

        // If the message text is just the invisible char, we know it's probably just an attachment
        const text = message.universalText(false) ?? "";
        const isOnlyMedia = text.length === 1 && text === invisibleMediaChar;

        // Default the message to the other message surrounded by greek quotes
        let msg = `“${text}”`;

        let matchingGuid: string = null;
        for (const i of message?.attributedBody ?? []) {
            for (const run of i?.runs ?? []) {
                if (run?.attributes?.__kIMMessagePartAttributeName === partIndex) {
                    matchingGuid = run?.attributes?.__kIMFileTransferGUIDAttributeName;
                    if (matchingGuid) break;
                }
            }

            if (matchingGuid) break;
        }

        // If we have a matching guid, we know it's an attachment. Pull it out
        let attachment = (message?.attachments ?? []).find(a => a.guid === matchingGuid);

        // If we don't have a match, but we know it's media only, select the first attachment
        if (!attachment && isOnlyMedia && isNotEmpty(message.attachments)) {
            attachment = message?.attachments[0];
        }

        // If we have an attachment, build the message based on the mime type
        if (attachment) {
            const mime = attachment.mimeType ?? "";
            const uti = attachment.uti ?? "";
            if (mime.startsWith("image")) {
                msg = `an image`;
            } else if (mime.startsWith("video")) {
                msg = `a movie`;
            } else if (mime.startsWith("audio") || uti.includes("coreaudio-format")) {
                msg = `an audio message`;
            } else {
                msg = `an attachment`;
            }
        } else {
            // If there is no attachment, use the message text
            msg = msg.replace(invisibleMediaChar, "");
        }

        // Build the final message to match on
        const messageText = `${prefix} ${msg}`;

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        const awaiter = new MessagePromise({ chatGuid, text: messageText, isAttachment: false, sentAt: now, tempGuid });
        Server().messageManager.add(awaiter);

        // Send the reaction
        const result = await Server().privateApi.message.react(chatGuid, message.guid, reaction, partIndex ?? 0);
        if (!result?.identifier) {
            throw new Error("Failed to send reaction! No message GUID returned.");
        } else {
            Server().log(`Reaction sent with Message GUID: ${result.identifier}`, "debug");
        }

        const maxWaitMs = 60000;
        let retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(result.identifier, true, false);
            }
        });

        // If we can't get the message via the transaction, try via the promise
        if (!retMessage) {
            retMessage = await awaiter.promise;
        }

        // Check if the name changed
        if (!retMessage) {
            throw new Error(
                `Failed to send reaction! Message not found in database after ${maxWaitMs / 1000} seconds!`
            );
        }

        // Return the message
        return retMessage;
    }

    static async notifySilencedMessage(chat: Chat, message: Message): Promise<Message> {
        checkPrivateApiStatus();
        if (!isMinMonterey) {
            throw new Error("Notifing silenced messages is only supported on macOS Monterey and newer!");
        }

        if (message.didNotifyRecipient) {
            throw new Error("The recipient has already been notified of this message!");
        }

        // Notify the recipient
        await Server().privateApi.message.notify(chat.guid, message.guid);

        // Wait for the didNotifyRecipient flag to be true
        const maxWaitMs = 30000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            // Keep looping until the didNotifyRecipient flag is true
            dataLoopCondition: (data: Message) => !data.didNotifyRecipient,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(message.guid, true, false);
            }
        });

        return retMessage;
    }

    static async getEmbeddedMedia(chat: Chat, message: Message): Promise<string | null> {
        checkPrivateApiStatus();
        if (!message.isDigitalTouch && !message.isHandwritten) {
            throw new Error("Message must be a digital touch message or handwritten message!");
        }

        // Get the media path via the private api
        const transaction = await Server().privateApi.message.getEmbeddedMedia(chat.guid, message.guid);
        if (!transaction?.data?.path) return null;
        const mediaPath = transaction.data.path.replace("file://", "");
        return mediaPath;
    }

    static async sendMultipart({
        chatGuid,
        attributedBody = null,
        subject = null,
        effectId = null,
        selectedMessageGuid = null,
        partIndex = 0,
        parts = [],
        ddScan = false
    }: SendMultipartTextParams): Promise<Message> {
        checkPrivateApiStatus();
        if (!chatGuid) throw new Error("No chat GUID provided");
        if (isEmpty(parts)) throw new Error("No parts provided");

        // Copy the attachments with the correct name.
        // And delete the original
        for (let i = 0; i < parts.length; i++) {
            if (parts[i].attachment) {
                const baseDir = FileSystem.getAttachmentDirectory("private-api");
                const currentPath = path.join(baseDir, parts[i].attachment);
                const newPath = FileSystem.copyAttachment(currentPath, parts[i].name, "private-api");
                parts[i].filePath = newPath;
            }
        }

        // Send the message
        const result = await Server().privateApi.message.sendMultipart(
            chatGuid,
            parts,
            attributedBody ?? null,
            subject ?? null,
            effectId ?? null,
            selectedMessageGuid ?? null,
            partIndex ?? 0,
            ddScan ?? false
        );

        if (!result?.identifier) {
            throw new Error("Failed to send message!");
        }

        const maxWaitMs = 60000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(result.identifier, true, false);
            }
        });

        // Check if the name changed
        if (!retMessage) {
            throw new Error(`Failed to send message! Message not found in database after ${maxWaitMs / 1000} seconds!`);
        }

        return retMessage;
    }

    static async sendPoll({
        chatGuid,
        title = null,
        question = null,
        message = null,
        options
    }: SendPollParams): Promise<{ message: Message; poll: PollData | null }> {
        checkPrivateApiStatus();
        if (!chatGuid) throw new Error("No chat GUID provided");
        if (isEmpty(options, false)) throw new Error("No poll options provided");

        const result = await Server().privateApi.message.sendPoll({
            chatGuid,
            title,
            question,
            message,
            options
        });

        if (!result?.identifier) {
            throw new Error("Failed to send poll!");
        }

        const maxWaitMs = 60000;
        const retMessage = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getMessage(result.identifier, true, false);
            }
        });

        if (!retMessage) {
            throw new Error(`Failed to send poll! Message not found in database after ${maxWaitMs / 1000} seconds!`);
        }

        return {
            message: retMessage,
            poll: result?.data?.poll ?? null
        };
    }

    static async readPoll({ chatGuid, messageGuid, message = null }: ReadPollParams): Promise<PollData> {
        checkPrivateApiStatus();
        if (!chatGuid) throw new Error("No chat GUID provided");
        if (!messageGuid) throw new Error("No message GUID provided");

        try {
            const result = await Server().privateApi.message.readPoll(chatGuid, messageGuid);
            const poll = result?.data?.poll;
            if (!poll) {
                throw new Error("Failed to read poll!");
            }

            return await MessageInterface.mergePollResponses(chatGuid, messageGuid, poll);
        } catch (ex) {
            const fallbackMessage = message ?? await Server().iMessageRepo.getMessage(messageGuid, true, false);
            const payloadPoll = MessageInterface.readPollFromPayload(fallbackMessage);
            if (payloadPoll) return await MessageInterface.mergePollResponses(chatGuid, messageGuid, payloadPoll);
            throw ex;
        }
    }

    static async searchMessagesPrivateApi({
        chatGuid = null,
        withChats = false,
        withAttachments = false,
        offset = 0,
        limit = 100,
        sort = "DESC",
        before = null,
        after = null,
        where = [],
        query,
        matchType = "contains"
    }: {
        chatGuid?: string,
        withChats?: boolean,
        withAttachments?: boolean,
        offset?: number,
        limit?: number,
        sort?: "ASC" | "DESC",
        before?: number | null,
        after?: number | null,
        where?: DBWhereItem[],
        query: string,
        matchType?: "contains" | "exact"
    }): Promise<[Message[], number]> {
        checkPrivateApiStatus();
        
        const result = await Server().privateApi.message.search(query, matchType);
        if (result?.data?.error) {
            throw new Error(`Failed to search messages: ${result.data.error}`);
        }

        const results = result.data.results ?? [];
        if (isEmpty(results)) return [[], 0];

        // Modify the WHERE clause to include the message GUIDs
        where.push({
            statement: `message.guid IN (:...guids)`,
            args: {
                guids: results
            }
        });

        // Fetch the info for the message by GUID
        return await Server().iMessageRepo.getMessages({
            chatGuid,
            withChats,
            withAttachments,
            offset,
            limit,
            sort,
            before,
            after,
            where: where ?? []
        });
    }
}
