/* eslint-disable max-len */
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { MessagePromise } from "@server/managers/outgoingMessageManager/messagePromise";
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
    sendMessageFallback,
    sendAttachmentAccessibility
} from "@server/api/v1/apple/scripts";
import { ValidRemoveTapback } from "../../../types";

import {
    safeExecuteAppleScript,
    generateChatNameList,
    getiMessageNumberFormat,
    toBoolean,
    slugifyAddress,
    isNotEmpty,
    isEmpty,
    safeTrim,
    isMinMonterey
} from "../../../helpers/utils";
import { tapbackUIMap } from "./mappings";

/**
 * This class handles all actions that require an AppleScript execution.
 * Pretty much, using command line to execute a script, passing any required
 * variables
 */
export class ActionHandler {
    static sendMessageHandler = async (chatGuid: string, message: string, attachment: string) => {
        let messageScript;

        let theAttachment = attachment;
        if (theAttachment !== null && theAttachment.endsWith('.mp3')) {
            try {
                const newPath = `${theAttachment.substring(0, theAttachment.length - 4)}.caf`;
                await FileSystem.convertMp3ToCaf(theAttachment, newPath);
                theAttachment = newPath;
            } catch (ex) {
                Server().log('Failed to convert MP3 to CAF!', 'warn');
            }
        }

        // Start the message send workflow
        //  1: Try sending using the input Chat GUID
        //    1.a: If there is a timeout error, we should restart the Messages App and retry
        //  2: If we still have an error, use the send message fallback script (only works for DMs)
        //  3: If we still have an error, throw the error
        let error;
        try {
            // Build the message script
            if (isMinMonterey) {
                // If it's monteray, we can't send attachments normally. We need to use accessibility
                // Make the first script send the image using accessibility. Then the second script sends
                // just the message
                if (isNotEmpty(theAttachment)) {
                    // Fetch participants of the chat and get handles (addresses)
                    const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
                    if (isNotEmpty(chats) && isNotEmpty(chats[0]?.participants)) {
                        const participants = chats[0].participants.map(i => i.id);
                        messageScript = sendAttachmentAccessibility(theAttachment, participants);
                        await FileSystem.executeAppleScript(messageScript);
                    }
                }

                messageScript = buildSendMessageScript(chatGuid, message ?? "", null);
            } else {
                messageScript = buildSendMessageScript(chatGuid, message ?? "", theAttachment);
            }

            // Try to send the message
            await FileSystem.executeAppleScript(messageScript);
        } catch (ex: any) {
            error = ex;
            Server().log(`Failed to send text via main AppleScript: ${error?.message ?? error}`, "debug");

            const errMsg = (ex?.message ?? "") as string;
            const retry = errMsg.toLowerCase().includes("timed out") || errMsg.includes("1002");

            // If we hit specific errors, we should retry after restarting the Messages App
            if (retry) {
                try {
                    Server().log(`[Retry] Sending AppleScript text after Messages restart...`, "debug");
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
                Server().log(`Sending AppleScript text using fallback script...`, "debug");
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

            Server().log(msg, "warn");
            throw new Error(msg);
        }
    };

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

        Server().log(`Sending message "${message}" ${attachment ? "with attachment" : ""} to ${chatGuid}`, "debug");

        // Make sure messages is open
        await FileSystem.startMessages();

        // We need offsets here due to iMessage's save times being a bit off for some reason
        const now = new Date(new Date().getTime() - 10000).getTime(); // With 10 second offset

        // Create the awaiter
        let messageAwaiter = null;
        if (isNotEmpty(message)) {
            messageAwaiter = new MessagePromise(chatGuid, message, false, now, undefined, tempGuid);
            Server().log(`Adding await for chat: "${chatGuid}"; text: ${messageAwaiter.text}`);
            Server().messageManager.add(messageAwaiter);
        }

        // Since we convert mp3s to cafs, we need to modify the attachment name here too
        // This is mainly just for the awaiter
        let aName = attachmentName;
        if (aName !== null && aName.endsWith('.mp3')) {
            aName = `${aName.substring(0, aName.length - 4)}.caf`;
        }

        // Create the awaiter
        let attachmentAwaiter = null;
        if (attachment && isNotEmpty(aName)) {
            attachmentAwaiter = new MessagePromise(chatGuid, `->${aName}`, true, now, undefined, attachmentGuid);
            Server().log(`Adding await for chat: "${chatGuid}"; attachment: ${aName}`);
            Server().messageManager.add(attachmentAwaiter);
        }

        // Hande-off params to send handler to actually send
        const theAttachment = attachment ? `${FileSystem.attachmentsDir}/${attachmentName}` : null;
        await ActionHandler.sendMessageHandler(chatGuid, message, theAttachment);

        // Wait for the attachment first
        if (attachmentAwaiter) {
            await attachmentAwaiter.promise;

        }

        // Next, wait for the message
        if (messageAwaiter) {
            await messageAwaiter.promise;
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
            } catch (ex: any) {
                err = ex;
                Server().log(`Failed to rename group from [${oldName}] to [${newName}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    static privateRenameGroupChat = async (chatGuid: string, newName: string): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            Server().log("Private API disabled! Not executing group rename...");
            return;
        }

        Server().log(`Executing Action: Changing chat display name (Chat: ${chatGuid}; NewName: ${newName};)`, "debug");
        Server().privateApiHelper.setDisplayName(chatGuid, newName);
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
            } catch (ex: any) {
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
            } catch (ex: any) {
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

        const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
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
            console.info(`Attempting to open chat, [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(openChat(name));
            } catch (ex: any) {
                err = ex;
                Server().log(`Failed to open chat, [${name}]. Trying again.`, "warn");
                continue;
            }
        }

        // If we get here, there was an issue
        throw err;
    };

    static startOrStopTypingInChat = async (chatGuid: string, isTyping: boolean): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            Server().log("Private API disabled! Not executing typing status change...");
            return;
        }

        Server().log(`Executing Action: Change Typing Status (Chat: ${chatGuid})`, "debug");
        if (isTyping) {
            await Server().privateApiHelper.startTyping(chatGuid);
        } else {
            await Server().privateApiHelper.stopTyping(chatGuid);
        }
    };

    static markChatRead = async (chatGuid: string): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            Server().log("Private API disabled! Not executing mark chat as read...");
            return;
        }

        Server().log(`Executing Action: Marking chat as read (Chat: ${chatGuid})`, "debug");
        await Server().privateApiHelper.markChatRead(chatGuid);
    };

    static updateTypingStatus = async (chatGuid: string): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            Server().log("Private API disabled! Not executing update typing status...");
            return;
        }

        Server().log(`Executing Action: Update Typing Status (Chat: ${chatGuid})`, "debug");
        await Server().privateApiHelper.getTypingStatus(chatGuid);
    };

    static togglePrivateTapback = async (
        chatGuid: string,
        actionMessageGuid: string,
        reactionType: ValidTapback | ValidRemoveTapback
    ): Promise<void> => {
        const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
        if (!enablePrivateApi) {
            Server().log("Private API disabled! Not executing tapback...");
            return;
        }

        Server().log(
            `Executing Action: Toggle Private Tapback (Chat: ${chatGuid}; Text: ${actionMessageGuid}; Tapback: ${reactionType})`,
            "debug"
        );
        await Server().privateApiHelper.sendReaction(chatGuid, actionMessageGuid, reactionType);
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
            } catch (ex: any) {
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
                return toBoolean(safeTrim(output));
            } catch (ex: any) {
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
    static createUniversalChat = async (
        participants: string[],
        service: string,
        message?: string,
        tempGuid?: string
    ): Promise<string> => {
        Server().log(`Executing Action: Create Chat Universal (Participants: ${participants.join(", ")})`, "debug");

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
                ret = (await FileSystem.executeAppleScript(startChat(buddies, service, true))) as string;
            } catch (ex: any) {
                // If the above command fails, try with just the `chat` qualifier
                ret = (await FileSystem.executeAppleScript(startChat(buddies, service, false))) as string;
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
                await ActionHandler.sendMessage(tempGuid, ret, message);
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
        Server().log(`Executing Action: Create Single Chat (Participant: ${participant})`, "debug");

        // Slugify the address
        const buddy = slugifyAddress(participant);

        // Make sure messages is open
        await FileSystem.startMessages();

        // Assume the chat GUID
        const chatGuid = `${service};-;${buddy}`;

        // Send the message to the chat
        await ActionHandler.sendMessage(tempGuid, chatGuid, message);

        // Return the chat GUID
        return chatGuid;
    };

    /**
     * Exports contacts from the Contacts app, into a VCF file
     *
     * @returns The command line response
     */
    static exportContacts = async (): Promise<void> => {
        Server().log("Executing Action: Export Contacts", "debug");

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
