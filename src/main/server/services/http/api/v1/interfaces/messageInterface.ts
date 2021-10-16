import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { MessagePromise } from "@server/services/messageManager/messagePromise";
import { ValidRemoveTapback, ValidTapback } from "@server/types";
import { Message } from "@server/databases/imessage/entity/Message";
import { checkPrivateApiStatus } from "@server/helpers/utils";
import { restartMessages, sendMessage, sendMessageFallback } from "@server/fileSystem/scripts";

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
        effectId?: string
    ): Promise<Message> {
        if (!chatGuid) throw new Error("No chat GUID provided");

        Server().log(`Sending message "${message}" to ${chatGuid}`, "debug");

        try {
            // Make sure messages is open
            await FileSystem.startMessages();

            // We need offsets here due to iMessage's save times being a bit off for some reason
            const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
            const awaiter = new MessagePromise(chatGuid, message, false, now);

            // Add the promise to the manager
            Server().messageManager.add(awaiter);

            // Try to send the iMessage
            if (method === "apple-script") {
                try {
                    await FileSystem.executeAppleScript(sendMessage(chatGuid, message ?? "", null));
                } catch (ex: any) {
                    // Log the actual error
                    Server().log(ex);

                    const errMsg = (ex?.message ?? "") as string;
                    const retry = errMsg.toLowerCase().includes("timed out") || errMsg.includes("1002");

                    if (retry) {
                        // If it's a plain ole retry case, retry after restarting Messages
                        Server().log("Message send error. Trying to re-send message...");
                        await FileSystem.executeAppleScript(restartMessages());
                        await FileSystem.executeAppleScript(sendMessage(chatGuid, message ?? "", null));
                    } else if (errMsg.includes("-1728") && chatGuid.includes(";-;")) {
                        // If our error has to do with not getting the chat ID, run the fallback script
                        Server().log("Message send error (can't get chat id). Running fallback send script...");
                        await FileSystem.executeAppleScript(sendMessageFallback(chatGuid, message ?? "", null));
                    }
                }
            } else if (method === "private-api") {
                checkPrivateApiStatus();
                await Server().privateApiHelper.sendMessage(chatGuid, message, subject ?? null, effectId ?? null);
            } else {
                throw new Error(`Invalid send method: ${method}`);
            }

            return awaiter.promise;
        } catch (ex: any) {
            let msg = ex?.message ?? ex;
            if (msg instanceof String) {
                if (msg.includes("execution error: ")) {
                    [, msg] = msg.split("execution error: ");
                    [msg] = msg.split(". (");
                    Server().log(msg, "warn");
                } else {
                    Server().log(msg, "error");
                }
            }

            throw new Error(msg);
        }
    }

    static async sendReaction(
        chatGuid: string,
        selectedMessageGuid: string,
        selectedMessageText: string,
        reaction: ValidTapback | ValidRemoveTapback
    ): Promise<Message> {
        checkPrivateApiStatus();

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        const awaiter = new MessagePromise(chatGuid, selectedMessageText, false, now);

        // Add the promise to the manager
        Server().messageManager.add(awaiter);

        // Send the reaction
        await Server().privateApiHelper.sendReaction(chatGuid, selectedMessageGuid, reaction);

        // Return the awaiter
        return awaiter.promise;
    }

    static async sendReply(chatGuid: string, selectedMessageGuid: string, message: string): Promise<Message> {
        checkPrivateApiStatus();

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset
        const awaiter = new MessagePromise(chatGuid, message, false, now);

        // Add the promise to the manager
        Server().messageManager.add(awaiter);

        // Send the reply
        await Server().privateApiHelper.sendReply(chatGuid, selectedMessageGuid, message);

        // Return the awaiter
        return awaiter.promise;
    }
}
