import { FileSystem } from "@server/fileSystem";
import { MessageRepository } from "@server/api/imessage";
import { ContactRepository } from "@server/api/contacts";
import { Message } from "@server/api/imessage/entity/Message";
import { safeExecuteAppleScript, generateChatNameList, getiMessageNumberFormat } from "./utils";

/**
 * This class handles all actions that require an AppleScript execution.
 * Pretty much, using command line to execute a script, passing any required
 * variables
 */
export class ActionHandler {
    fs: FileSystem;

    iMessageRepo: MessageRepository;

    contactsRepo: ContactRepository;

    /**
     * Constructor to set some vars
     *
     * @param fileSystem The instance of the filesystem for the app
     */
    constructor(fileSystem: FileSystem, iMessageRepo: MessageRepository, contactsRepo: ContactRepository) {
        this.fs = fileSystem;
        this.iMessageRepo = iMessageRepo;
        this.contactsRepo = contactsRepo;
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
    sendMessage = async (
        chatGuid: string,
        message: string,
        attachmentName?: string,
        attachment?: Uint8Array
    ): Promise<Message> => {
        if (!chatGuid.startsWith("iMessage"))
            throw new Error("Invalid chat GUID!");

        // Create the base command to execute
        let baseCmd = `osascript "${this.fs.scriptDir}/sendMessage.scpt" "${chatGuid}" "${message}"`;

        // Add attachment, if present
        if (attachment) {
            this.fs.saveAttachment(attachmentName, attachment);
            baseCmd += ` "${this.fs.attachmentsDir}/${attachmentName}"`;
        }

        try {
            // Track the time it takes to execute the function
            const start = new Date(new Date().getTime() - 1000);
            const ret = await this.fs.execShellCommand(baseCmd) as string;

            // Lookup the corresponding message in the DB
            const matchingMessages = await this.iMessageRepo.getMessages({
                chatGuid,
                limit: 1,
                withHandle: false,  // Exclude to speed up query
                after: start,
                where: [
                    {
                        // Text must match
                        statement: "message.text = :text",
                        args: { text: message }
                    },
                    {
                        // Text must be from yourself
                        statement: "message.is_from_me = :fromMe",
                        args: { fromMe: 1 }
                    }
                ]
            });
            return matchingMessages.length === 0 ? null : matchingMessages[0];
        } catch (ex) {
            // Format the error a bit, and re-throw it
            const msg = ex.message.split('execution error: ')[1];
            throw new Error(msg.split('. (')[0]);
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
    renameGroupChat = async (chatGuid: string, newName: string): Promise<string> => {
        const names = await generateChatNameList(chatGuid, this.iMessageRepo, this.contactsRepo);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        let err = null;
        for (const oldName of names) {
            console.info(`Attempting rename group from [${oldName}] to [${newName}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    this.fs, `osascript "${this.fs.scriptDir}/renameGroupChat.scpt" "${oldName}" "${newName}"`);
            } catch (ex) {
                err = ex;
                console.warn(`Failed to rename group from [${oldName}] to [${newName}]. Attempting the next name.`);
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
    addParticipant = async (chatGuid: string, participant: string): Promise<string> => {
        const names = await generateChatNameList(chatGuid, this.iMessageRepo, this.contactsRepo);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        let err = null;
        for (const name of names) {
            console.info(`Attempting to add participant to group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    this.fs, `osascript "${this.fs.scriptDir}/addParticipant.scpt" "${name}" "${participant}"`);
            } catch (ex) {
                err = ex;
                console.warn(`Failed to add participant to group, [${name}]. Attempting the next name.`);
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
    removeParticipant = async (chatGuid: string, participant: string): Promise<string> => {
        const names = await generateChatNameList(chatGuid, this.iMessageRepo, this.contactsRepo);
        let address = participant;
        if (!address.includes("@")) {
            address = getiMessageNumberFormat(address);
        }

        console.log(address);

        /**
         * Above, we calculate 2 different names. One as-is, returned by the chat query, and one
         * ordered by the chat_handle_join table insertions. Below, we try to try to find the
         * corresponding chats, and rename them. If the first name fails to be found,
         * we are going to try and use the backup (second) name. If both failed, we weren't able to
         * calculate the correct chat name
         */

        let err = null;
        for (const name of names) {
            console.info(`Attempting to remove participant from group [${name}]`);
            try {
                // This needs await here, or else it will fail
                return await safeExecuteAppleScript(
                    this.fs, `osascript "${this.fs.scriptDir}/removeParticipant.scpt" "${name}" "${address}"`);
            } catch (ex) {
                err = ex;
                console.warn(`Failed to remove participant from group, [${name}]. Attempting the next name.`);
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
    createChat = async (
        participants: string[]
    ): Promise<string> => {
        if (participants.length === 0)
            throw new Error("No participants specified!");

        // Create the base command to execute
        let baseCmd = `osascript "${this.fs.scriptDir}/startChat.scpt"`;

        // Add members to the chat
        participants.forEach((member) => {
            baseCmd += ` "${member}"`;
        });

        // Execute the command
        let ret = (await this.fs.execShellCommand(baseCmd)) as string;

        try {
            // Get the chat GUID that was created
            ret = ret.split("text chat id")[1].trim();
        } catch (ex) {
            throw new Error("Failed to get chat GUID from new chat!")
        }

        return ret;
    };
}
