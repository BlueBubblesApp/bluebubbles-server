import * as fs from "fs";

import * as path from "path";
import * as child_process from "child_process";
import { transports } from "electron-log";
import { app } from "electron";
import { sync } from "read-chunk";
import { Server } from "@server";
import {
    escapeDoubleQuote,
    concatUint8Arrays,
    parseMetadataString,
    isNotEmpty,
    isEmpty,
    safeTrim
} from "@server/helpers/utils";
import { Attachment } from "@server/databases/imessage/entity/Attachment";

import { startMessages } from "../api/v1/apple/scripts";
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

// Patch in original user data directory
app.setPath('userData', app.getPath('userData').replace('@bluebubbles/server', 'bluebubbles-server'));

// Directory modifiers based on the environment
let subdir = "";
let moddir = "app.asar.unpacked";
let appPath = __dirname.replace("/app.asar/dist", "");
if (process.env.NODE_ENV !== "production") {
    appPath = __dirname.replace("/dist", "");
    subdir = "bluebubbles-server";
    moddir = "";
}

export const userHomeDir = () => {
    return process?.env?.HOME ?? process?.env?.HOMEPATH ?? process?.env?.USERPROFILE;
};

/**
 * The class used to handle all communications to the App's "filesystem".
 * The filesystem is the directory dedicated to the app-specific files
 */
export class FileSystem {
    public static baseDir = path.join(app.getPath("userData"), subdir);

    public static attachmentsDir = path.join(FileSystem.baseDir, "Attachments");

    public static attachmentCacheDir = path.join(FileSystem.baseDir, "Attachments", "Cached");

    public static certsDir = path.join(FileSystem.baseDir, "Certs");

    public static themesDir = path.join(FileSystem.baseDir, "Themes");

    public static settingsDir = path.join(FileSystem.baseDir, "Settings");

    public static contactsDir = path.join(FileSystem.baseDir, "Contacts");

    public static convertDir = path.join(FileSystem.baseDir, "Convert");

    public static fcmDir = path.join(FileSystem.baseDir, "FCM");

    public static modules = path.join(appPath, moddir, "node_modules");

    public static resources = path.join(appPath, "appResources");

    public static addressBookFile = `${FileSystem.contactsDir}/AddressBook.vcf`;

    public static contactsFile = `${FileSystem.contactsDir}/contacts.vcf`;

    // Private API directories
    public static usrMySimblPlugins = path.join(userHomeDir(), "Library", "Application Support", "SIMBL", "Plugins");

    public static libMySimblPlugins = `/${path.join("Library", "Application Support", "SIMBL", "Plugins")}`;

    public static usrMacForgePlugins = path.join(
        userHomeDir(),
        "Library",
        "Application Support",
        "MacEnhance",
        "Plugins"
    );

    public static libMacForgePlugins = `/${path.join("Library", "Application Support", "MacEnhance", "Plugins")}`;

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
        if (!fs.existsSync(FileSystem.attachmentCacheDir)) fs.mkdirSync(FileSystem.attachmentCacheDir);
        if (!fs.existsSync(FileSystem.convertDir)) fs.mkdirSync(FileSystem.convertDir);
        if (!fs.existsSync(FileSystem.contactsDir)) fs.mkdirSync(FileSystem.contactsDir);
        if (!fs.existsSync(FileSystem.fcmDir)) fs.mkdirSync(FileSystem.fcmDir);
        if (!fs.existsSync(FileSystem.certsDir)) fs.mkdirSync(FileSystem.certsDir);
        if (!fs.existsSync(FileSystem.themesDir)) fs.mkdirSync(FileSystem.themesDir);
        if (!fs.existsSync(FileSystem.settingsDir)) fs.mkdirSync(FileSystem.settingsDir);
    }

    static cachedAttachmentPath(attachment: Attachment, name: string) {
        return path.join(FileSystem.attachmentCacheDir, attachment.guid, name);
    }

    static cachedAttachmentExists(attachment: Attachment, name: string) {
        const basePath = this.cachedAttachmentPath(attachment, name);
        return fs.existsSync(basePath);
    }

    static saveCachedAttachment(attachment: Attachment, name: string, data: Buffer) {
        const basePath = path.join(FileSystem.attachmentCacheDir, attachment.guid);
        if (!fs.existsSync(basePath)) {
            fs.mkdirSync(basePath, { recursive: true });
        }

        fs.writeFileSync(path.join(basePath, name), data);
    }

    /**
     * Saves an attachment
     *
     * @param name Name for the attachment
     * @param buffer The attachment bytes (buffer)
     */
    static saveAttachment(name: string, buffer: Uint8Array): string {
        const newPath = path.join(FileSystem.attachmentsDir, name);
        fs.writeFileSync(newPath, buffer);
        return newPath;
    }

    /**
     * Saves an attachment
     *
     * @param name Name for the attachment
     * @param buffer The attachment bytes (buffer)
     */
    static copyAttachment(originalPath: string, name: string): string {
        const newPath = path.join(FileSystem.attachmentsDir, name);
        if (newPath !== originalPath) {
            fs.copyFileSync(originalPath, newPath);
        }
        return newPath;
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
        return FileSystem.execShellCommand(`tail -n ${count} ${filePath}`);
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
    static buildAttachmentChunks(guid: string, name: string): string {
        let chunks = new Uint8Array(0);

        // Get the files in ascending order
        const files = fs.readdirSync(path.join(FileSystem.attachmentsDir, guid));
        files.sort((a, b) => Number(a.split(".")[0]) - Number(b.split(".")[0]));

        // Read the files and append to chunks
        for (const file of files) {
            const fileData = fs.readFileSync(path.join(FileSystem.attachmentsDir, guid, file));
            chunks = concatUint8Arrays(chunks, Uint8Array.from(fileData));
        }

        // Write the final file to disk
        const outFile = path.join(FileSystem.attachmentsDir, guid, name);
        fs.writeFileSync(outFile, chunks);

        return outFile;
    }

    /**
     * Saves a VCF file
     *
     * @param vcf The VCF data to save
     */
    static saveVCF(vcf: string): void {
        // Delete the file if it exists
        if (fs.existsSync(FileSystem.contactsFile)) {
            fs.unlinkSync(FileSystem.contactsFile);
        }

        // Writes the file to disk
        fs.writeFileSync(FileSystem.contactsFile, vcf);
    }

    /**
     * Gets a VCF file
     */
    static getVCF(): string | null {
        // Delete the file if it exists
        if (!fs.existsSync(FileSystem.contactsFile)) {
            return null;
        }

        // Reads the VCF file
        return fs.readFileSync(FileSystem.contactsFile).toString();
    }

    /**
     * Saves the Client FCM JSON file
     *
     * @param contents The object data for the FCM client
     */
    static saveFCMClient(contents: any): void {
        const filePath = path.join(FileSystem.fcmDir, "client.json");
        if ((!contents) && fs.existsSync(filePath)) {
            fs.unlinkSync(filePath);
        } else {
            fs.writeFileSync(filePath, JSON.stringify(contents));
        } 
    }

    /**
     * Saves the Server FCM JSON file
     *
     * @param contents The object data for the FCM server
     */
    static saveFCMServer(contents: any): void {
        const filePath = path.join(FileSystem.fcmDir, "server.json");
        if ((!contents) && fs.existsSync(filePath)) {
            fs.unlinkSync(filePath);
        } else {
            fs.writeFileSync(filePath, JSON.stringify(contents));
        } 
    }

    /**
     * Gets the FCM client data
     *
     * @returns The parsed FCM client data
     */
    static getFCMClient(): any {
        const filePath = path.join(FileSystem.fcmDir, "client.json");
        if (!fs.existsSync(filePath)) return null;
        const contents = fs.readFileSync(filePath, "utf8");
        if (!contents || contents.length === 0) return null;
        return JSON.parse(contents);
    }

    /**
     * Gets the FCM server data
     *
     * @returns The parsed FCM server data
     */
    static getFCMServer(): any {
        const filePath = path.join(FileSystem.fcmDir, "server.json");
        if (!fs.existsSync(filePath)) return null;
        const contents = fs.readFileSync(filePath, "utf8");
        if (!contents || contents.length === 0) return null;
        return JSON.parse(contents);
    }

    /**
     * Deletes an attachment from the app's image cache
     *
     * @param name The name of the attachment to delete
     */
    static removeAttachment(name: string): void {
        try {
            fs.unlinkSync(path.join(FileSystem.attachmentsDir, name));
        } catch (ex: any) {
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
        if (isEmpty(cmd)) return null;

        let parts = cmd.split("\n");
        parts = parts
            .map(i => safeTrim(escapeDoubleQuote(i)))
            .filter(i => isNotEmpty(i))
            .map(i => `"${i}"`);

        return FileSystem.execShellCommand(`osascript -e ${parts.join(" -e ")}`);
    }

    /**
     * Makes sure that Messages is running
     */
    static async startMessages() {
        await FileSystem.executeAppleScript(startMessages());
    }

    static deleteAddressBook() {
        try {
            fs.unlinkSync(FileSystem.addressBookFile);
        } catch (ex: any) {
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

    static async convertMp3ToCaf(inputPath: string, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(inputPath);
        await FileSystem.execShellCommand(
            `/usr/bin/afconvert -f caff -d LEI16@44100 -c 1 "${oldPath}" "${outputPath}"`);
    }

    static async convertToJpg(format: string, attachment: Attachment, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(attachment.filePath);
        await FileSystem.execShellCommand(
            `/usr/bin/sips --setProperty "format" "${format}" "${oldPath}" --out "${outputPath}"`);
    }

    static async isSipDisabled(): Promise<boolean> {
        const res = (await FileSystem.execShellCommand(`csrutil status`) ?? '').trim();
        return !res.endsWith('enabled.');
    }

    static async hasFullDiskAccess(): Promise<boolean> {
        const res = (await FileSystem.execShellCommand(
            `defaults read ~/Library/Preferences/com.apple.universalaccessAuthWarning.plist`) ?? '').trim();
        return res.includes('BlueBubbles.app" = 1') || res.includes('BlueBubbles" = 1')
    }

    static async getFileMetadata(filePath: string): Promise<{ [key: string]: string }> {
        try {
            return parseMetadataString(await FileSystem.execShellCommand(`mdls "${FileSystem.getRealPath(filePath)}"`));
        } catch (ex: any) {
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
            } catch (ex: any) {
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
