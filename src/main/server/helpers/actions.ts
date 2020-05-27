import { FileSystem } from "@server/fileSystem";

/**
 * This class handles all actions that require an AppleScript execution.
 * Pretty much, using command line to execute a script, passing any required
 * variables
 */
export class ActionHandler {
    fs: FileSystem;

    /**
     * Constructor to set some vars
     *
     * @param fileSystem The instance of the filesystem for the app
     */
    constructor(fileSystem: FileSystem) {
        this.fs = fileSystem;
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
    ): Promise<string> => {
        if (!chatGuid.startsWith("iMessage"))
            throw new Error("Invalid chat GUID!");

        // Create the base command to execute
        let baseCmd = `osascript "${this.fs.scriptDir}/sendMessage.scpt" "${chatGuid}" "${message}"`;

        // Add attachment, if present
        if (attachment) {
            this.fs.saveAttachment(attachmentName, attachment);
            baseCmd += ` "${this.fs.attachmentsDir}/${attachmentName}"`;
        }

        // Execute the command
        const ret = await this.fs.execShellCommand(baseCmd) as string;
        return ret;
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