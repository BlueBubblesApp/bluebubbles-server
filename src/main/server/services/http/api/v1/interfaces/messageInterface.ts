import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { MessagePromise } from "@server/services/messageManager/messagePromise";
import { ValidRemoveTapback, ValidTapback } from "@server/types";
import { Message } from "@server/databases/imessage/entity/Message";
import { checkPrivateApiStatus, waitMs } from "@server/helpers/utils";
import { restartMessages, sendMessage, sendMessageFallback } from "@server/fileSystem/scripts";
import { negativeReactionTextMap, reactionTextMap } from "@server/helpers/mappings";
import { invisibleMediaChar } from "@server/services/http/constants";
import { Queue } from "@server/databases/server/entity";
import { ActionHandler } from "@server/helpers/actions";

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
    static async sendMessageSync(
        chatGuid: string,
        message: string,
        method: "apple-script" | "private-api",
        subject?: string,
        effectId?: string,
        selectedMessageGuid?: string,
        tempGuid?: string
    ): Promise<Message> {
        if (!chatGuid) throw new Error("No chat GUID provided");

        Server().log(`Sending message "${message}" to ${chatGuid}`, "debug");

        // Make sure messages is open
        await FileSystem.startMessages();

        // Try to send the iMessage
        if (method === "apple-script") {
            // NOTE: Moved to only apple script so we can use transactions for other
            // We need offsets here due to iMessage's save times being a bit off for some reason
            const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
            const awaiter = new MessagePromise(chatGuid, message, false, now);

            // Add the promise to the manager
            Server().messageManager.add(awaiter);

            // Attempt to send the message
            await ActionHandler.sendMessageHandler(chatGuid, message ?? "", null);

            // If we have a tempGuid, it means we should add an item to the queue
            if (tempGuid) {
                const item = new Queue();
                item.tempGuid = tempGuid;
                item.chatGuid = chatGuid;
                item.dateCreated = now;
                item.text = message ?? "";
                await Server().repo.queue().manager.save(item);
            }

            // Return the promise
            return awaiter.promise;
        }

        if (method === "private-api") {
            return MessageInterface.sendMessagePrivateApi(chatGuid, message, subject, effectId, selectedMessageGuid);
        }

        throw new Error(`Invalid send method: ${method}`);
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
    static async sendAttachmentSync(
        chatGuid: string,
        attachmentPath: string,
        attachmentName?: string,
        attachmentGuid?: string
    ): Promise<Message> {
        if (!chatGuid) throw new Error("No chat GUID provided");

        // Copy the attachment to a more permanent storage
        const newPath = FileSystem.copyAttachment(attachmentPath, attachmentName);

        Server().log(`Sending attachment "${attachmentName}" to ${chatGuid}`, "debug");

        // Make sure messages is open
        await FileSystem.startMessages();

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        const awaiter = new MessagePromise(chatGuid, `->${attachmentName}`, true, now);

        // Add the promise to the manager
        Server().messageManager.add(awaiter);

        // Send the message
        await ActionHandler.sendMessageHandler(chatGuid, "", newPath);

        // If we were given a GUID (tempGuid), it means we have to add a "queue" item
        if (attachmentGuid) {
            const attachmentItem = new Queue();
            attachmentItem.tempGuid = attachmentGuid;
            attachmentItem.chatGuid = chatGuid;
            attachmentItem.dateCreated = now;
            attachmentItem.text = `${attachmentGuid}->${attachmentName}`;
            await Server().repo.queue().manager.save(attachmentItem);
        }

        // Return the promise
        return awaiter.promise;
    }

    static async sendMessagePrivateApi(
        chatGuid: string,
        message: string,
        subject?: string | null,
        effectId?: string | null,
        selectedMessageGuid?: string | null
    ) {
        checkPrivateApiStatus();
        const result = await Server().privateApiHelper.sendMessage(
            chatGuid,
            message,
            subject ?? null,
            effectId ?? null,
            selectedMessageGuid ?? null
        );

        if (!result?.identifier) {
            throw new Error("Failed to send message!");
        }

        // Fetch the chat based on the return data
        let retMessage = await Server().iMessageRepo.getMessage(result.identifier, true, false);
        let tryCount = 0;
        while (!retMessage) {
            tryCount += 1;

            // If we've tried 10 times and there is no change, break out (~5 seconds)
            if (tryCount >= 10) break;

            // Give it a bit to execute
            await waitMs(500);

            // Re-fetch the message with the updated information
            retMessage = await Server().iMessageRepo.getMessage(result.identifier, true, false);
        }

        // Check if the name changed
        if (!retMessage) {
            throw new Error("Failed to send message! Message not found after 5 seconds!");
        }

        return retMessage;
    }

    static async sendReaction(
        chatGuid: string,
        message: Message,
        reaction: ValidTapback | ValidRemoveTapback,
        tempGuid?: string | null
    ): Promise<Message> {
        checkPrivateApiStatus();

        // NOTE: Removed to test transaction system
        // We need offsets here due to iMessage's save times being a bit off for some reason
        // const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        // const awaiter = new MessagePromise(chatGuid, messageText, false, now);
        // Server().messageManager.add(awaiter);

        // Add the reaction to the match queue
        // NOTE: This can be removed when we move away from socket-style matching
        if (tempGuid && tempGuid.length > 0) {
            // Rebuild the selected message text to make it what the reaction text
            // would be in the database
            const prefix = (reaction as string).startsWith("-")
                ? negativeReactionTextMap[reaction as string]
                : reactionTextMap[reaction as string];

            // If the message text is just the invisible char, we know it's probably just an attachment
            const isOnlyMedia = message.text.length === 1 && message.text === invisibleMediaChar;

            // Default the message to the other message surrounded by greek quotes
            let msg = `“${message.text}”`;

            // If it's a media-only message and we have at least 1 attachment,
            // set the message according to the first attachment's MIME type
            if (isOnlyMedia && (message.attachments ?? []).length > 0) {
                if (message.attachments[0].mimeType.startsWith("image")) {
                    msg = `an image`;
                } else if (message.attachments[0].mimeType.startsWith("video")) {
                    msg = `a movie`;
                } else {
                    msg = `an attachment`;
                }
            }

            // Build the final message to match on
            const messageText = `${prefix} ${msg}`;
            Server().log(`Adding message to match queue with text: ${messageText}`, "debug");

            const item = new Queue();
            item.tempGuid = tempGuid;
            item.chatGuid = chatGuid;
            item.dateCreated = new Date().getTime();
            item.text = messageText;
            await Server().repo.queue().manager.save(item);
        }

        // Send the reaction
        const result = await Server().privateApiHelper.sendReaction(chatGuid, message.guid, reaction);
        if (!result?.identifier) {
            throw new Error("Failed to send reaction! No message GUID returned.");
        } else {
            Server().log(`Reaction sent with Message GUID: ${result.identifier}`, "debug");
        }

        // Fetch the chat based on the return data
        let retMessage = await Server().iMessageRepo.getMessage(result.identifier, true, false);
        let tryCount = 0;
        while (!retMessage) {
            tryCount += 1;

            // If we've tried 10 times and there is no change, break out (~5 seconds)
            if (tryCount >= 10) break;

            // Give it a bit to execute
            await waitMs(500);

            // Re-fetch the message with the updated information
            retMessage = await Server().iMessageRepo.getMessage(result.identifier, true, false);
        }

        // Check if the name changed
        if (!retMessage) {
            throw new Error("Failed to send reaction! Message not found after 5 seconds!");
        }

        // Return the message
        return retMessage;
    }
}
