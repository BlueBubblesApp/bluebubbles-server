import * as fs from "fs";
import * as stream from "stream";
import * as readline from "readline";

import * as path from "path";
import * as child_process from "child_process";
import { transports } from "electron-log";
import { app } from "electron";
import { sync } from "read-chunk";
import { Server } from "@server/index";
import { escapeDoubleQuote, concatUint8Arrays, parseMetadataString } from "@server/helpers/utils";
import { Attachment } from "@server/databases/imessage/entity/Attachment";

import { startMessages } from "./scripts";
import {
    AudioMetadata,
    AudioMetadataKeys,
    MetadataDataTypes,
    MetadataKeyMap,
    VideoMetadataKeys,
    VideoMetadata,
    ImageMetadata,
    ImageMetadataKeys
} from "./types";

// Directory modifiers based on the environment
let subdir = "";
let moddir = "app.asar.unpacked";
let appPath = __dirname.replace("/app.asar/dist", "");
if (process.env.NODE_ENV !== "production") {
    appPath = __dirname.replace("/dist", "");
    subdir = "bluebubbles-server";
    moddir = "";
}

/**
 * The class used to handle all communications to the App's "filesystem".
 * The filesystem is the directory dedicated to the app-specific files
 */
export class FileSystem {
    public static baseDir = path.join(app.getPath("userData"), subdir);

    public static attachmentsDir = path.join(FileSystem.baseDir, "Attachments");

    public static contactsDir = path.join(FileSystem.baseDir, "Contacts");

    public static convertDir = path.join(FileSystem.baseDir, "Convert");

    public static fcmDir = path.join(FileSystem.baseDir, "FCM");

    public static modules = path.join(appPath, moddir, "node_modules");

    public static resources = path.join(appPath, "appResources");

    public static contactsVcf = `${FileSystem.contactsDir}/AddressBook.vcf`;

    /**
     * Sets up all required directories and then, writes the scripts
     * to the scripts directory
     */
    static async setup(): Promise<void> {
        FileSystem.setupDirectories();
    }

    /**
     * Creates required directories
     */
    static setupDirectories(): void {
        if (!fs.existsSync(FileSystem.baseDir)) fs.mkdirSync(FileSystem.baseDir);
        if (!fs.existsSync(FileSystem.attachmentsDir)) fs.mkdirSync(FileSystem.attachmentsDir);
        if (!fs.existsSync(FileSystem.convertDir)) fs.mkdirSync(FileSystem.convertDir);
        if (!fs.existsSync(FileSystem.contactsDir)) fs.mkdirSync(FileSystem.contactsDir);
        if (!fs.existsSync(FileSystem.fcmDir)) fs.mkdirSync(FileSystem.fcmDir);
    }

    /**
     * Saves an attachment
     *
     * @param name Name for the attachment
     * @param buffer The attachment bytes (buffer)
     */
    static saveAttachment(name: string, buffer: Uint8Array): void {
        fs.writeFileSync(path.join(FileSystem.attachmentsDir, name), buffer);
    }

    /**
     * Saves an attachment by chunk
     *
     * @param guid Unique identifier for the attachment
     * @param chunkNumber The index of the chunk (for ordering/reassembling)
     * @param buffer The attachment chunk bytes (buffer)
     */
    static saveAttachmentChunk(guid: string, chunkNumber: number, buffer: Uint8Array): void {
        const parent = path.join(FileSystem.attachmentsDir, guid);
        if (!fs.existsSync(parent)) fs.mkdirSync(parent);
        fs.writeFileSync(path.join(parent, `${chunkNumber}.chunk`), buffer);
    }

    static getLogs({ count = 100 }): Promise<string> {
        const fPath = transports.file.getFile().path;
        return FileSystem.readLastLines({
            filePath: fPath,
            count
        });
    }

    private static readLastLines({ filePath, count = 100 }: { filePath: string; count?: number }): Promise<string> {
        const inStream = fs.createReadStream(filePath);
        const outStream = new stream.Writable();
        return new Promise((resolve, reject) => {
            const rl = readline.createInterface(inStream, outStream);

            let output = "";
            let lineCount = 0;
            rl.on("line", line => {
                lineCount += 1;
                output += `${line}\n`;

                if (lineCount >= count) {
                    resolve(output);
                }
            });

            rl.on("error", reject);

            rl.on("close", () => {
                resolve(output);
            });
        });
    }

    /**
     * Removes a chunk directory
     *
     * @param guid Unique identifier for the attachment
     */
    static deleteChunks(guid: string): void {
        const dir = path.join(FileSystem.attachmentsDir, guid);
        if (fs.existsSync(dir)) fs.rmdirSync(dir, { recursive: true });
    }

    /**
     * Builds an attachment by combining all chunks
     *
     * @param guid Unique identifier for the attachment
     */
    static buildAttachmentChunks(guid: string): Uint8Array {
        let chunks = new Uint8Array(0);

        // Get the files in ascending order
        const files = fs.readdirSync(path.join(FileSystem.attachmentsDir, guid));
        files.sort((a, b) => Number(a.split(".")[0]) - Number(b.split(".")[0]));

        // Read the files and append to chunks
        for (const file of files) {
            const fileData = fs.readFileSync(path.join(FileSystem.attachmentsDir, guid, file));
            chunks = concatUint8Arrays(chunks, Uint8Array.from(fileData));
        }

        return chunks;
    }

    /**
     * Saves the Client FCM JSON file
     *
     * @param contents The object data for the FCM client
     */
    static saveFCMClient(contents: any): void {
        fs.writeFileSync(path.join(FileSystem.fcmDir, "client.json"), JSON.stringify(contents));
    }

    /**
     * Saves the Server FCM JSON file
     *
     * @param contents The object data for the FCM server
     */
    static saveFCMServer(contents: any): void {
        fs.writeFileSync(path.join(FileSystem.fcmDir, "server.json"), JSON.stringify(contents));
    }

    /**
     * Gets the FCM client data
     *
     * @returns The parsed FCM client data
     */
    static getFCMClient(): any {
        const filePath = path.join(FileSystem.fcmDir, "client.json");
        if (!fs.existsSync(filePath)) return null;

        return JSON.parse(fs.readFileSync(filePath, "utf8"));
    }

    /**
     * Gets the FCM server data
     *
     * @returns The parsed FCM server data
     */
    static getFCMServer(): any {
        const filePath = path.join(FileSystem.fcmDir, "server.json");
        if (!fs.existsSync(filePath)) return null;

        return JSON.parse(fs.readFileSync(filePath, "utf8"));
    }

    /**
     * Deletes an attachment from the app's image cache
     *
     * @param name The name of the attachment to delete
     */
    static removeAttachment(name: string): void {
        try {
            fs.unlinkSync(path.join(FileSystem.attachmentsDir, name));
        } catch (ex) {
            Server().log(`Could not remove attachment: ${ex.message}`, "error");
        }
    }

    static readFileChunk(filePath: string, start: number, chunkSize = 1024): Uint8Array {
        // Get the file size
        const stats = fs.statSync(filePath);
        let fStart = start;

        // Make sure the start are not bigger than the size
        if (fStart > stats.size) fStart = stats.size;
        return Uint8Array.from(sync(filePath, fStart, chunkSize));
    }

    /**
     * Loops over all the files in the attachments directory,
     * then call the delete method
     */
    static purgeAttachments(): void {
        const files = fs.readdirSync(FileSystem.attachmentsDir);
        files.forEach(file => {
            FileSystem.removeAttachment(file);
        });
    }

    /**
     * Asynchronously executes a shell command
     */
    static async execShellCommand(cmd: string): Promise<string> {
        const { exec } = child_process;
        return new Promise((resolve, reject) => {
            exec(cmd, (error, stdout, stderr) => {
                if (error) {
                    reject(error);
                }

                resolve(stdout || stderr);
            });
        });
    }

    static async executeAppleScript(cmd: string) {
        if (!cmd || cmd.length === 0) return null;

        let parts = cmd.split("\n");
        parts = parts
            .map(i => escapeDoubleQuote(i).trim())
            .filter(i => i && i.length > 0)
            .map(i => `"${i}"`);

        return FileSystem.execShellCommand(`osascript -e ${parts.join(" -e ")}`);
    }

    /**
     * Makes sure that Messages is running
     */
    static async startMessages() {
        await FileSystem.executeAppleScript(startMessages());
    }

    static deleteContactsVcf() {
        try {
            fs.unlinkSync(FileSystem.contactsVcf);
        } catch (ex) {
            // Do nothing
        }
    }

    static getRealPath(filePath: string) {
        let output = filePath;
        if (output[0] === "~") {
            output = path.join(process.env.HOME, output.slice(1));
        }

        return output;
    }

    static async convertCafToMp3(attachment: Attachment, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(attachment.filePath);
        await FileSystem.execShellCommand(`/usr/bin/afconvert -f m4af -d aac "${oldPath}" "${outputPath}"`);
    }

    static async getFileMetadata(filePath: string): Promise<{ [key: string]: string }> {
        try {
            return parseMetadataString(await FileSystem.execShellCommand(`mdls "${FileSystem.getRealPath(filePath)}"`));
        } catch (ex) {
            return null;
        }
    }

    private static async parseMetadata(filePath: string, parserKeyDefinition: MetadataKeyMap): Promise<any> {
        const metadata: { [key: string]: string } = await FileSystem.getFileMetadata(filePath);
        if (!metadata) return null;

        const getNumber = (num: string) => {
            if (!num) return null;

            try {
                return Number.parseFloat(num);
            } catch (ex) {
                return null;
            }
        };

        const meta: { [key: string]: any } = {};
        for (const [key, value] of Object.entries(metadata)) {
            if (!(key in parserKeyDefinition)) continue;

            // Get the types info for the field
            const { dataType, metaKey } = parserKeyDefinition[key];

            // Parse the item by type
            let itemValue: any;
            switch (dataType) {
                case MetadataDataTypes.Bool:
                    itemValue = value === "1";
                    break;
                case MetadataDataTypes.Float:
                    itemValue = getNumber(value);
                    break;
                case MetadataDataTypes.Int:
                    itemValue = Math.trunc(getNumber(value));
                    break;
                default:
                    itemValue = value;
                    break;
            }

            meta[metaKey] = itemValue;
        }

        return meta;
    }

    static async getAudioMetadata(audioPath: string): Promise<AudioMetadata> {
        const meta = await FileSystem.parseMetadata(audioPath, AudioMetadataKeys);
        return meta as AudioMetadata;
    }

    static async getVideoMetadata(videoPath: string): Promise<VideoMetadata> {
        const meta = await FileSystem.parseMetadata(videoPath, VideoMetadataKeys);
        return meta as VideoMetadata;
    }

    static async getImageMetadata(imagePath: string): Promise<ImageMetadata> {
        const meta = await FileSystem.parseMetadata(imagePath, ImageMetadataKeys);
        return meta as ImageMetadata;
    }
}
