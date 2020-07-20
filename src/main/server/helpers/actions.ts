import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { Queue } from "@server/databases/server/entity/Queue";
import { ValidTapback } from "@server/types";

import {
    safeExecuteAppleScript,
    generateChatNameList,
    getiMessageNumberFormat,
    cliSanitize,
    tapbackUIMap,
    toBoolean
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
        if (!chatGuid.startsWith("iMessage")) throw new Error("Invalid chat GUID!");

        // Create the base command to execute
        let baseCmd = `osascript "${FileSystem.scriptDir}/sendMessage.scpt" "${chatGuid}" "${cliSanitize(
            message ?? ""
        )}"`;

        // Add attachment, if present
        if (attachment) {
            FileSystem.saveAttachment(attachmentName, attachment);
            baseCmd += ` "${FileSystem.attachmentsDir}/${attachmentName}"`;
        }

        try {
            // Make sure messages is open
            await FileSystem.startMessages();

            // We need offsets here due to iMessage's save times being a bit off for some reason
            const now = new Date(new Date().getTime() - 1000).getTime(); // With 1 second offset
            await FileSystem.execShellCommand(baseCmd);

            // Add queued item
            if (message && message.length > 0) {
                const item = new Queue();
                item.tempGuid = tempGuid;
                item.chatGuid = chatGuid;
                item.dateCreated = now;
                item.text = message;
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
            if (msg instanceof String) [, msg] = msg.split("execution error: ");
            [msg] = msg.split(". (");

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
        const names = await generateChatNameList(chatGuid, Server().iMessageRepo, Server().contactsRepo);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is open
        await FileSystem.startMessages();

        let err = null;
        for (const oldName of names) {
            console.info(`Attempting rename group from [${oldName}] to [${newName}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    `osascript "${FileSystem.scriptDir}/renameGroupChat.scpt" "${cliSanitize(oldName)}" "${cliSanitize(
                        newName
                    )}"`
                );
            } catch (ex) {
                err = ex;
                Server().log(`Failed to rename group from [${oldName}] to [${newName}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
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
        const names = await generateChatNameList(chatGuid, Server().iMessageRepo, Server().contactsRepo);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is open
        await FileSystem.startMessages();

        let err = null;
        for (const name of names) {
            console.info(`Attempting to add participant to group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    `osascript "${FileSystem.scriptDir}/addParticipant.scpt" "${name}" "${participant}"`
                );
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
        const names = await generateChatNameList(chatGuid, Server().iMessageRepo, Server().contactsRepo);
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

        // Make sure messages is open
        await FileSystem.startMessages();

        let err = null;
        for (const name of names) {
            console.info(`Attempting to remove participant from group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    `osascript "${FileSystem.scriptDir}/removeParticipant.scpt" "${name}" "${address}"`
                );
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
     * Toggles a tapback to specific message in a chat
     *
     * @param chatGuid The GUID for the chat
     * @param text The message text
     * @param tapback The tapback to send (as a strong)
     *
     * @returns The command line response
     */
    static toggleTapback = async (chatGuid: string, text: string, tapback: ValidTapback): Promise<string> => {
        const names = await generateChatNameList(chatGuid, Server().iMessageRepo, Server().contactsRepo);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        const tapbackId = tapbackUIMap[tapback];
        const friendlyMsg = text.substring(0, 50);

        // Make sure messages is open
        await FileSystem.startMessages();

        let err = null;
        for (const name of names) {
            console.info(`Attempting to toggle tapback for message [${friendlyMsg}]`);

            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    `osascript "${FileSystem.scriptDir}/toggleTapback.scpt" "${name}" "${cliSanitize(
                        text
                    )}" "${tapbackId}"`
                );
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
        const names = await generateChatNameList(chatGuid, Server().iMessageRepo, Server().contactsRepo);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        // Make sure messages is open
        await FileSystem.startMessages();

        let err = null;
        for (const name of names) {
            console.info(`Attempting to check for a typing indicator for chat, [${name}]`);
            try {
                // This needs await here, or else it will fail
                const output = await safeExecuteAppleScript(
                    `osascript "${FileSystem.scriptDir}/checkTypingIndicator.scpt" "${name}"`
                );
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
    static createChat = async (participants: string[]): Promise<string> => {
        if (participants.length === 0) throw new Error("No participants specified!");

        // Create the base command to execute
        let baseCmd = `osascript "${FileSystem.scriptDir}/startChat.scpt"`;

        // Add members to the chat
        participants.forEach(member => {
            baseCmd += ` "${member}"`;
        });

        // Make sure messages is open
        await FileSystem.startMessages();

        // Execute the command
        let ret = (await FileSystem.execShellCommand(baseCmd)) as string;

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
        // Create the base command to execute
        const baseCmd = `osascript "${FileSystem.scriptDir}/exportContacts.scpt"`;

        try {
            await FileSystem.execShellCommand(baseCmd);
        } catch (ex) {
            let msg = ex.message;
            if (msg instanceof String) [, msg] = msg.split("execution error: ");
            [msg] = msg.split(". (");

            throw new Error(msg);
        }
    };
}
