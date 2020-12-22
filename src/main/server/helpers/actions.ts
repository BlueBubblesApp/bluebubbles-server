/* eslint-disable max-len */
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { Queue } from "@server/databases/server/entity/Queue";
import { ValidTapback } from "@server/types";
import {
    sendMessage,
    startChat,
    renameGroupChat,
    addParticipant,
    removeParticipant,
    toggleTapback,
    checkTypingIndicator,
    exportContacts,
    restartMessages,
    openChat
} from "@server/fileSystem/scripts";
import { ValidRemoveTapback } from "../types";

import {
    safeExecuteAppleScript,
    generateChatNameList,
    getiMessageNumberFormat,
    tapbackUIMap,
    toBoolean,
    slugifyAddress
} from "./utils";

/**
 * This class handles all actions that require an AppleScript execution.
 * Pretty much, using command line to execute a script, passing any required
 * variables
 */
export class ActionHandler {
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
    static sendMessage = async (
        tempGuid: string,
        chatGuid: string,
        message: string,
        attachmentGuid?: string,
        attachmentName?: string,
        attachment?: Uint8Array
    ): Promise<void> => {
        if (!chatGuid) throw new Error("No chat GUID provided");

        // Add attachment, if present
        if (attachment) {
            FileSystem.saveAttachment(attachmentName, attachment);
        }

        try {
            // Make sure messages is open
            await FileSystem.startMessages();

            // We need offsets here due to iMessage's save times being a bit off for some reason
            const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset

            // Try to send the iMessage
            try {
                await FileSystem.executeAppleScript(
                    sendMessage(
                        chatGuid,
                        message ?? "",
                        attachment ? `${FileSystem.attachmentsDir}/${attachmentName}` : null
                    )
                );
            } catch (ex) {
                // Log the actual error
                Server().log(ex);

                const errMsg = (ex?.message ?? "") as string;
                const retry = errMsg.includes("AppleEvent timed out") || errMsg.includes("1002");

                // If we don't want to retry, throw the original error
                if (!retry) throw ex;

                Server().log("Message send error. Trying to re-send message...");

                // If it's a restartable-error, restart iMessage and retry
                await FileSystem.executeAppleScript(restartMessages());
                await FileSystem.executeAppleScript(
                    sendMessage(
                        chatGuid,
                        message ?? "",
                        attachment ? `${FileSystem.attachmentsDir}/${attachmentName}` : null
                    )
                );
            }

            // Add queued item
            if (message && message.length > 0) {
                const item = new Queue();
                item.tempGuid = tempGuid;
                item.chatGuid = chatGuid;
                item.dateCreated = now;
                item.text = message ?? "";
                await Server().repo.queue().manager.save(item);
            }

            // If there is an attachment, add that to the queue too
            if (attachment && attachmentName) {
                const attachmentItem = new Queue();
                attachmentItem.tempGuid = attachmentGuid;
                attachmentItem.chatGuid = chatGuid;
                attachmentItem.dateCreated = now;
                attachmentItem.text = `${attachmentGuid}->${attachmentName}`;
                await Server().repo.queue().manager.save(attachmentItem);
            }
        } catch (ex) {
            let msg = ex.message;
            if (msg instanceof String) {
                [, msg] = msg.split("execution error: ");
                [msg] = msg.split(". (");
            }

            Server().log(msg, "warn");
            throw new Error(msg);
        }
    };

    /**
     * Renames a group chat via an AppleScript
     *
     * @param chatGuid The GUID for the chat
     * @param newName The new name for the group
     *
     * @returns The command line response
     */
    static renameGroupChat = async (chatGuid: string, newName: string): Promise<string> => {
        Server().log(`Executing Action: Rename Group (Chat: ${chatGuid}; Name: ${newName})`, "debug");

        const names = await generateChatNameList(chatGuid);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is restarted to prevent accessibility issues
        await FileSystem.executeAppleScript(restartMessages());

        let err = null;
        for (const oldName of names) {
            console.info(`Attempting rename group from [${oldName}] to [${newName}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(renameGroupChat(oldName, newName));
            } catch (ex) {
                err = ex;
                Server().log(`Failed to rename group from [${oldName}] to [${newName}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    static privateRenameGroupChat = async (chatGuid: string, newName: string): Promise<void> => {
        Server().log(`Executing Action: Changing chat display name (Chat: ${chatGuid}; NewName: ${newName};)`, "debug");
        Server().blueBubblesServerHelper.setDisplayName(chatGuid, newName);
    };

    /**
     * Adds a participant using an AppleScript
     *
     * @param chatGuid The GUID for the chat
     * @param participant The paticipant to add
     *
     * @returns The command line response
     */
    static addParticipant = async (chatGuid: string, participant: string): Promise<string> => {
        Server().log(`Executing Action: Add Participant (Chat: ${chatGuid}; Participant: ${participant})`, "debug");

        const names = await generateChatNameList(chatGuid);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is restarted to prevent accessibility issues
        await FileSystem.executeAppleScript(restartMessages());

        let err = null;
        for (const name of names) {
            console.info(`Attempting to add participant to group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(addParticipant(name, participant));
            } catch (ex) {
                err = ex;
                Server().log(`Failed to add participant to group, [${name}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    /**
     * Removes a participant using an AppleScript
     *
     * @param chatGuid The GUID for the chat
     * @param participant The paticipant to remove
     *
     * @returns The command line response
     */
    static removeParticipant = async (chatGuid: string, participant: string): Promise<string> => {
        Server().log(`Executing Action: Remove Participant (Chat: ${chatGuid}; Participant: ${participant})`, "debug");

        const names = await generateChatNameList(chatGuid);
        let address = participant;
        if (!address.includes("@")) {
            address = getiMessageNumberFormat(address);
        }

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is restarted to prevent accessibility issues
        await FileSystem.executeAppleScript(restartMessages());

        let err = null;
        for (const name of names) {
            console.info(`Attempting to remove participant from group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(removeParticipant(name, participant));
            } catch (ex) {
                err = ex;
                Server().log(`Failed to remove participant to group, [${name}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    /**
     * Opens a chat in iMessage
     *
     * @param chatGuid The GUID for the chat
     *
     * @returns The command line response
     */
    static openChat = async (chatGuid: string): Promise<string> => {
        Server().log(`Executing Action: Open Chat (Chat: ${chatGuid})`, "debug");

        const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true, withSMS: true });
        if (!chats || chats.length === 0) throw new Error("Chat does not exist");
        if (chats[0].participants.length > 1) throw new Error("Chat is a group chat");

        const names = await generateChatNameList(chatGuid);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is restarted to prevent accessibility issues
        await FileSystem.executeAppleScript(restartMessages());

        let err = null;
        for (const name of names) {
            console.info(`Attempting to open chat, [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(openChat(name));
            } catch (ex) {
                err = ex;
                Server().log(`Failed to open chat, [${name}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    static startOrStopTypingInChat = async (chatGuid: string, isTyping: boolean): Promise<void> => {
        Server().log(`Executing Action: Change Typing Status (Chat: ${chatGuid})`, "debug");
        if (isTyping) {
            Server().blueBubblesServerHelper.startTyping(chatGuid);
        } else {
            Server().blueBubblesServerHelper.stopTyping(chatGuid);
        }
    };

    static markChatRead = async (chatGuid: string): Promise<void> => {
        Server().log(`Executing Action: Marking chat as read (Chat: ${chatGuid})`, "debug");
        Server().blueBubblesServerHelper.markChatRead(chatGuid);
    };

    static updateTypingStatus = async (chatGuid: string): Promise<void> => {
        Server().log(`Executing Action: Update Typing Status (Chat: ${chatGuid})`, "debug");
        Server().blueBubblesServerHelper.getTypingStatus(chatGuid);
    };

    static togglePrivateTapback = async (
        chatGuid: string,
        actionMessageGuid: string,
        reactionType: ValidTapback | ValidRemoveTapback
    ): Promise<void> => {
        Server().log(
            `Executing Action: Toggle Private Tapback (Chat: ${chatGuid}; Text: ${actionMessageGuid}; Tapback: ${reactionType})`,
            "debug"
        );
        Server().blueBubblesServerHelper.sendReaction(chatGuid, actionMessageGuid, reactionType);
    };

    /**
     * Toggles a tapback to specific message in a chat
     *
     * @param chatGuid The GUID for the chat
     * @param text The message text
     * @param tapback The tapback to send (as a strong)
     *
     * @returns The command line response
     */
    static toggleTapback = async (chatGuid: string, text: string, tapback: ValidTapback): Promise<string> => {
        Server().log(
            `Executing Action: Toggle Tapback (Chat: ${chatGuid}; Text: ${text}; Tapback: ${tapback})`,
            "debug"
        );

        const names = await generateChatNameList(chatGuid);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        const tapbackId = tapbackUIMap[tapback];
        const friendlyMsg = text.substring(0, 50);

        // Make sure messages is restarted to prevent accessibility issues
        await FileSystem.executeAppleScript(restartMessages());

        let err = null;
        for (const name of names) {
            console.info(`Attempting to toggle tapback for message [${friendlyMsg}]`);

            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(toggleTapback(name, text, tapbackId));
            } catch (ex) {
                err = ex;
                Server().log(`Failed to toggle tapback on message, [${friendlyMsg}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    /**
     * Checks to see if a typing indicator is present
     *
     * @param chatGuid The GUID for the chat
     *
     * @returns Boolean on whether a typing indicator was present
     */
    static checkTypingIndicator = async (chatGuid: string): Promise<boolean> => {
        Server().log(`Executing Action: Check Typing Indicators (Chat: ${chatGuid})`, "debug");

        const names = await generateChatNameList(chatGuid);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is restarted to prevent accessibility issues
        await FileSystem.executeAppleScript(restartMessages());

        let err = null;
        for (const name of names) {
            console.info(`Attempting to check for a typing indicator for chat, [${name}]`);
            try {
                // This needs await here, or else it will fail
                const output = await safeExecuteAppleScript(checkTypingIndicator(name));
                if (!output) return false;
                return toBoolean(output.trim());
            } catch (ex) {
                err = ex;
                Server().log(`Failed to check for typing indicators for chat, [${name}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    /**
     * Creates a new chat using a list of participants (strings)
     *
     * @param participants: The list of participants to include in the chat
     *
     * @returns The GUID of the new chat
     */
    static createChat = async (participants: string[], service: string): Promise<string> => {
        Server().log(`Executing Action: Create Chat (Participants: ${participants.join(", ")}`, "debug");

        if (participants.length === 0) throw new Error("No participants specified!");

        // Add members to the chat
        const buddies = participants.map(item => slugifyAddress(item));

        // Make sure messages is open
        await FileSystem.startMessages();

        // Execute the command
        let ret = (await FileSystem.executeAppleScript(startChat(buddies, service))) as string;

        try {
            // Get the chat GUID that was created
            ret = ret.split("text chat id")[1].trim();
        } catch (ex) {
            throw new Error("Failed to get chat GUID from new chat!");
        }

        return ret;
    };

    /**
     * Exports contacts from the Contacts app, into a VCF file
     *
     * @returns The command line response
     */
    static exportContacts = async (): Promise<void> => {
        Server().log("Executing Action: Export Contacts", "debug");

        try {
            FileSystem.deleteContactsVcf();
            await FileSystem.executeAppleScript(exportContacts());
        } catch (ex) {
            let msg = ex.message;
            if (msg instanceof String) [, msg] = msg.split("execution error: ");
            [msg] = msg.split(". (");

            throw new Error(msg);
        }
    };
}
