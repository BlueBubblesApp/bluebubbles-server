/* eslint-disable max-len */
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { ValidTapback } from "@server/types";
import {
    sendMessage as buildSendMessageScript,
    startChat,
    renameGroupChat,
    addParticipant,
    removeParticipant,
    toggleTapback,
    checkTypingIndicator,
    exportContacts,
    restartMessages,
    openChat,
    sendMessageFallback
} from "@server/api/apple/scripts";
import { ValidRemoveTapback } from "../../types";

import {
    safeExecuteAppleScript,
    generateChatNameList,
    getiMessageAddressFormat,
    toBoolean,
    slugifyAddress,
    isNotEmpty,
    isEmpty,
    safeTrim
} from "../../helpers/utils";
import { tapbackUIMap } from "./mappings";
import { MessageInterface } from "../interfaces/messageInterface";
import { getLogger } from "../../lib/logging/Loggable";

const log = getLogger("ActionHandler");

/**
 * This class handles all actions that require an AppleScript execution.
 * Pretty much, using command line to execute a script, passing any required
 * variables
 */
export class ActionHandler {
    static sendMessage = async (chatGuid: string, message: string, attachment: string, isAudioMessage = false) => {
        let messageScript: string;

        let theAttachment = attachment;
        if (theAttachment !== null && theAttachment.endsWith(".mp3") && isAudioMessage) {
            try {
                const newPath = `${theAttachment.substring(0, theAttachment.length - 4)}.caf`;
                await FileSystem.convertMp3ToCaf(theAttachment, newPath);
                theAttachment = newPath;
            } catch (ex) {
                log.warn("Failed to convert MP3 to CAF!");
            }
        }

        // Start the message send workflow
        //  1: Try sending using the input Chat GUID
        //    1.a: If there is a timeout error, we should restart the Messages App and retry
        //  2: If we still have an error, use the send message fallback script (only works for DMs)
        //  3: If we still have an error, throw the error
        let error;
        try {
            messageScript = buildSendMessageScript(chatGuid, message ?? "", theAttachment);

            // Try to send the message
            await FileSystem.executeAppleScript(messageScript);
        } catch (ex: any) {
            error = ex;
            log.debug(`Failed to send text via main AppleScript: ${error?.message ?? error}`);

            const errMsg = (ex?.message ?? "") as string;
            const retry = errMsg.toLowerCase().includes("timed out") || errMsg.includes("1002");

            // If we hit specific errors, we should retry after restarting the Messages App
            if (retry) {
                try {
                    log.debug(`[Retry] Sending AppleScript text after Messages restart...`);
                    await FileSystem.executeAppleScript(restartMessages());
                    await FileSystem.executeAppleScript(messageScript);
                } catch (ex2: any) {
                    error = ex2;
                }
            }
        }

        // If we have an error, we should attempt to use the fallback script
        if (error) {
            // Clear the error
            error = null;

            try {
                // Generate the new send script
                log.debug(`Sending AppleScript text using fallback script...`);
                messageScript = sendMessageFallback(chatGuid, message ?? "", theAttachment);
                await FileSystem.executeAppleScript(messageScript);
            } catch (ex: any) {
                error = ex;
            }
        }

        if (error) {
            let msg = error?.message ?? error;

            // If the error is a string and contains a specific error message,
            // Re-throw the shortened error
            if (msg instanceof String && msg.includes("execution error: ")) {
                [, msg] = msg.split("execution error: ");
                [msg] = msg.split(". (");
            }

            log.warn(msg);
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
        log.debug(`Executing Action: Rename Group (Chat: ${chatGuid}; Name: ${newName})`);

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
            log.info(`Attempting rename group from [${oldName}] to [${newName}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(renameGroupChat(oldName, newName));
            } catch (ex: any) {
                err = ex;
                log.warn(`Failed to rename group from [${oldName}] to [${newName}]. Trying again.`);
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    static privateRenameGroupChat = async (chatGuid: string, newName: string): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            log.info("Private API disabled! Not executing group rename...");
            return;
        }

        log.debug(`Executing Action: Changing chat display name (Chat: ${chatGuid}; NewName: ${newName};)`);
        Server().privateApi.chat.setDisplayName(chatGuid, newName);
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
        log.debug(`Executing Action: Add Participant (Chat: ${chatGuid}; Participant: ${participant})`);

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
            log.info(`Attempting to add participant to group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(addParticipant(name, participant));
            } catch (ex: any) {
                err = ex;
                log.warn(`Failed to add participant to group, [${name}]. Trying again.`);
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
        log.debug(`Executing Action: Remove Participant (Chat: ${chatGuid}; Participant: ${participant})`);

        const names = await generateChatNameList(chatGuid);
        let address = participant;
        if (!address.includes("@")) {
            address = getiMessageAddressFormat(address, false, true);
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
            log.info(`Attempting to remove participant from group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(removeParticipant(name, participant));
            } catch (ex: any) {
                err = ex;
                log.warn(`Failed to remove participant to group, [${name}]. Trying again.`);
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
        log.debug(`Executing Action: Open Chat (Chat: ${chatGuid})`);

        const [chats, _] = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
        if (isEmpty(chats)) throw new Error("Chat does not exist");
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
            log.info(`Attempting to open chat, [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(openChat(name));
            } catch (ex: any) {
                err = ex;
                log.warn(`Failed to open chat, [${name}]. Trying again.`);
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    static startOrStopTypingInChat = async (chatGuid: string, isTyping: boolean): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            log.info("Private API disabled! Not executing typing status change...");
            return;
        }

        log.debug(`Executing Action: Change Typing Status (Chat: ${chatGuid})`);
        if (isTyping) {
            await Server().privateApi.chat.startTyping(chatGuid);
        } else {
            await Server().privateApi.chat.stopTyping(chatGuid);
        }
    };

    static markChatRead = async (chatGuid: string): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            log.info("Private API disabled! Not executing mark chat as read...");
            return;
        }

        log.debug(`Executing Action: Marking chat as read (Chat: ${chatGuid})`);
        await Server().privateApi.chat.markRead(chatGuid);
    };

    static updateTypingStatus = async (chatGuid: string): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            log.info("Private API disabled! Not executing update typing status...");
            return;
        }

        log.debug(`Executing Action: Update Typing Status (Chat: ${chatGuid})`);
        await Server().privateApi.chat.getTypingStatus(chatGuid);
    };

    static togglePrivateTapback = async (
        chatGuid: string,
        actionMessageGuid: string,
        reactionType: ValidTapback | ValidRemoveTapback
    ): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            log.info("Private API disabled! Not executing tapback...");
            return;
        }

        log.debug(
            `Executing Action: Toggle Private Tapback (Chat: ${chatGuid}; Text: ${actionMessageGuid}; Tapback: ${reactionType})`
        );
        await Server().privateApi.message.react(chatGuid, actionMessageGuid, reactionType);
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
        log.debug(`Executing Action: Toggle Tapback (Chat: ${chatGuid}; Text: ${text}; Tapback: ${tapback})`);

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
            log.info(`Attempting to toggle tapback for message [${friendlyMsg}]`);

            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(toggleTapback(name, text, tapbackId));
            } catch (ex: any) {
                err = ex;
                log.warn(`Failed to toggle tapback on message, [${friendlyMsg}]. Trying again.`);
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
        log.debug(`Executing Action: Check Typing Indicators (Chat: ${chatGuid})`);

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
            log.info(`Attempting to check for a typing indicator for chat, [${name}]`);
            try {
                // This needs await here, or else it will fail
                const output = await safeExecuteAppleScript(checkTypingIndicator(name));
                if (!output) return false;
                return toBoolean(safeTrim(output));
            } catch (ex: any) {
                err = ex;
                log.warn(`Failed to check for typing indicators for chat, [${name}]. Trying again.`);
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
    static createUniversalChat = async (
        participants: string[],
        service: string,
        message?: string,
        tempGuid?: string
    ): Promise<string> => {
        log.debug(`Executing Action: Create Chat Universal (Participants: ${participants.join(", ")})`);

        if (isEmpty(participants)) throw new Error("No participants specified!");

        // Add members to the chat
        const buddies = participants.map(item => slugifyAddress(item));

        // Make sure messages is open
        await FileSystem.startMessages();

        // Execute the command
        let ret = "";

        try {
            try {
                // First try to send via the AppleScript using the `text chat` qualifier
                ret = (await FileSystem.executeAppleScript(startChat(buddies, service))) as string;
            } catch (ex: any) {
                // If the above command fails, try with just the `chat` qualifier
                ret = (await FileSystem.executeAppleScript(startChat(buddies, service))) as string;
            }
        } catch (ex: any) {
            // If we failed to create the chat, we can try to "guess" the
            // This catch catches the 2nd attempt to start a chat
            throw new Error(`AppleScript error: ${ex}`);
        }

        // Get the chat GUID that was created
        if (ret.includes("text chat id")) {
            ret = safeTrim(ret.split("text chat id")[1]);
        } else if (ret.includes("chat id")) {
            ret = safeTrim(ret.split("chat id")[1]);
        }

        // If no chat ID found, throw an error
        if (isEmpty(ret)) {
            throw new Error("Failed to get Chat GUID from AppleScript response!");
        }

        // If there is a message attached, try to send it
        try {
            if (isNotEmpty(message) && isNotEmpty(tempGuid)) {
                await MessageInterface.sendMessageSync({
                    chatGuid: ret,
                    message: message,
                    tempGuid: tempGuid,
                    method: "apple-script"
                });
            }
        } catch (ex: any) {
            throw new Error(`Failed to send message to chat, ${ret}!`);
        }

        return ret;
    };

    /**
     * Creates a new chat using a participant
     *
     * @param participant: The participant to include in the chat
     *
     * @returns The GUID of the new chat
     */
    static createSingleChat = async (
        participant: string,
        service: string,
        message: string,
        tempGuid: string
    ): Promise<string> => {
        log.debug(`Executing Action: Create Single Chat (Participant: ${participant})`);

        // Slugify the address
        const buddy = getiMessageAddressFormat(participant);

        // Make sure messages is open
        await FileSystem.startMessages();

        // Assume the chat GUID
        const chatGuid = `${service};-;${buddy}`;

        // Send the message to the chat
        await MessageInterface.sendMessageSync({
            chatGuid: chatGuid,
            message: message,
            tempGuid: tempGuid,
            method: "apple-script"
        });

        // Return the chat GUID
        return chatGuid;
    };

    /**
     * Exports contacts from the Contacts app, into a VCF file
     *
     * @returns The command line response
     */
    static exportContacts = async (): Promise<void> => {
        log.debug("Executing Action: Export Contacts");

        try {
            FileSystem.deleteAddressBook();
            await FileSystem.executeAppleScript(exportContacts());
        } catch (ex: any) {
            let msg = ex.message;
            if (msg instanceof String) [, msg] = msg.split("execution error: ");
            [msg] = msg.split(". (");

            throw new Error(msg);
        }
    };
}
