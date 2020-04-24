import { FileSystem } from "@server/fileSystem";
import { DatabaseRepository } from "../api/imessage";

export class ActionHandler {
    fs: FileSystem;

    repo: DatabaseRepository;

    constructor(fileSystem: FileSystem, repo: DatabaseRepository) {
        this.fs = fileSystem;
        this.repo = repo;
    }

    sendMessage = async (
        chatGuid: string,
        message: string,
        attachmentName?: string,
        attachment?: Buffer | string
    ): Promise<string> => {
        if (!chatGuid.startsWith("iMessage"))
            throw new Error("Invalid chat GUID!");

        // Create the base command to execute
        let baseCmd = `osascript "${this.fs.scriptDir}/sendMessage.scpt" "${chatGuid}" "${message}"`;

        // Add attachment, if present
        if (attachment && attachment instanceof Buffer) {
            this.fs.saveAttachment(attachmentName, attachment);
            baseCmd += ` "${this.fs.attachmentsDir}/${attachmentName}"`;
        }

        // Execute the command
        const ret = await this.fs.execShellCommand(baseCmd) as string;
        return ret;
    };

    createChat = async (
        fs: FileSystem,
        participants: string[]
    ): Promise<string> => {
        if (participants.length === 0)
            throw new Error("No participants specified!");

        // Create the base command to execute
        let baseCmd = `osascript "${fs.scriptDir}/startChat.scpt"`;

        // Add members to the chat
        participants.forEach((member) => {
            baseCmd += ` "${member}"`;
        });

        // Execute the command
        let ret = (await fs.execShellCommand(baseCmd)) as string;

        try {
            // Get the chat GUID that was created
            ret = ret.split("text chat id")[1].trim();
        } catch (ex) {
            throw new Error("Failed to get chat GUID from new chat!")
        }

        return ret;
    };
}
