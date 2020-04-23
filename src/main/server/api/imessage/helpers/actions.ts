import { FileSystem } from "@server/fileSystem";

export const sendMessage = async (fs: FileSystem, chatGuid: string, message: string, attachmentName?: string, attachment?: Buffer | string): Promise<any> => {
    if (!chatGuid.startsWith("iMessage")) throw new Error("Invalid chat GUID!")

    // Create the base command to execute
    let baseCmd = `osascript "${fs.scriptDir}/sendMessage.scpt" "${chatGuid}" "${message}"`;

    // Add attachment, if present
    if (attachment && attachment instanceof Buffer) {
        fs.saveAttachment(attachmentName, attachment)
        baseCmd += ` "${fs.attachmentsDir}/${attachmentName}"`;
    }

    // Execute the command
    const ret = await fs.execShellCommand(baseCmd);
    return ret;
}

export const createChat = async (
    fs: FileSystem,
    participants: string[]
): Promise<any> => {
    if (participants.length === 0) throw new Error("No participants specified!");

    // Create the base command to execute
    let baseCmd = `osascript "${fs.scriptDir}/startChat.scpt"`;

    // Add members to the chat
    participants.forEach(member => {
        baseCmd += ` "${member}"`;
    })

    // Execute the command
    let ret = await fs.execShellCommand(baseCmd) as string;

    try {
        // Get the chat GUID that was created
        ret = ret.split("text chat id")[1].trim();
    } catch (ex) {
        // Don't do anything
    }

    return ret;
};