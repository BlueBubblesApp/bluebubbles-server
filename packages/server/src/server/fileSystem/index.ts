import * as fs from "fs";
import * as path from "path";
import * as os from "os";
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
import { isMinMonterey } from "@server/env";
import { Attachment } from "@server/databases/imessage/entity/Attachment";

import { startMessages } from "../api/apple/scripts";
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
import { uuidv4 } from "@firebase/util";

const FindProcess = require("find-process");
const { rimrafSync } = require("rimraf");

// Patch in original user data directory
app.setPath("userData", app.getPath("userData").replace("@bluebubbles/server", "bluebubbles-server"));

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

    public static cfgFile = path.join(userHomeDir(), "bluebubbles.yml");

    public static attachmentsDir = path.join(FileSystem.baseDir, "Attachments");

    public static iMessageAttachmentsDir = path.join(userHomeDir(), "Library", "Messages", "Attachments");

    public static messagesAttachmentsDir = path.join(
        userHomeDir(),
        "Library",
        "Messages",
        "Attachments",
        "BlueBubbles"
    );

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

    public static findMyDir = path.join(userHomeDir(), "Library", "Caches", "com.apple.findmy.fmipcore");

    public static findMyFriendsDir = path.join(userHomeDir(), "Library", "Caches", "com.apple.icloud.fmfd");

    public static get usingCustomFcm(): boolean {
        const fcmClient = Server().args["fcm-client"];
        const fcmServer = Server().args["fcm-server"];
        return !!(fcmClient && fcmServer);
    }

    public static get fcmClientPath(): string {
        const fcmClient = Server().args["fcm-client"];
        return fcmClient ?? path.join(FileSystem.fcmDir, "client.json");
    }

    public static get fcmServerPath(): string {
        const fcmServer = Server().args["fcm-server"];
        return fcmServer ?? path.join(FileSystem.fcmDir, "server.json");
    }

    public static async getUserConfDir(): Promise<string> {
        return (await FileSystem.execShellCommand(`/usr/bin/getconf DARWIN_USER_DIR`)).trim();
    }

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

        if (isMinMonterey) {
            if (!fs.existsSync(FileSystem.iMessageAttachmentsDir)) fs.mkdirSync(FileSystem.iMessageAttachmentsDir);
            if (!fs.existsSync(FileSystem.messagesAttachmentsDir)) fs.mkdirSync(FileSystem.messagesAttachmentsDir);
        }
    }

    static cachedAttachmentPath(attachment: Attachment, name: string) {
        return path.join(FileSystem.attachmentCacheDir, attachment.originalGuid ?? attachment.guid, name);
    }

    static cachedAttachmentExists(attachment: Attachment, name: string) {
        const basePath = this.cachedAttachmentPath(attachment, name);
        return fs.existsSync(basePath);
    }

    static saveCachedAttachment(attachment: Attachment, name: string, data: Buffer) {
        const basePath = path.join(FileSystem.attachmentCacheDir, attachment.originalGuid ?? attachment.guid);
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
        let newFile = FileSystem.getAttachmentDirectory(null);
        if (!fs.existsSync(newFile)) fs.mkdirSync(newFile, { recursive: true });
        newFile = path.join(newFile, name);
        fs.writeFileSync(newFile, buffer);
        return newFile;
    }

    static getAttachmentDirectory(method: string): string {
        if (isMinMonterey || method === "private-api") {
            return FileSystem.messagesAttachmentsDir;
        } else {
            return FileSystem.attachmentsDir;
        }
    }

    /**
     * Saves an attachment
     *
     * @param name Name for the attachment
     * @param buffer The attachment bytes (buffer)
     */
    static copyAttachment(originalPath: string, name: string, method = "apple-script"): string {
        // Generate a random folder to put it in. This is so we don't have file name overlap
        const guid = uuidv4();
        const dir = FileSystem.getAttachmentDirectory(method);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

        let newPath = path.join(dir, guid);
        if (!fs.existsSync(newPath)) fs.mkdirSync(newPath, { recursive: true });
        newPath = path.join(newPath, name);

        if (newPath !== originalPath) {
            fs.copyFileSync(originalPath, newPath);
        }

        return newPath;
    }

    static async cachedAttachmentCount() {
        let count = 0;
        const files = [FileSystem.attachmentsDir, FileSystem.attachmentCacheDir, FileSystem.messagesAttachmentsDir];

        for (const file of files) {
            if (fs.existsSync(file)) {
                count += (await FileSystem.getFiles(file)).length;
            }
        }

        return count;
    }

    static clearAttachmentCaches() {
        const files = [FileSystem.attachmentsDir, FileSystem.attachmentCacheDir];

        for (const file of files) {
            if (fs.existsSync(file)) {
                rimrafSync(file);
            }

            fs.mkdirSync(file);
        }
    }

    static async getCachedAttachmentsSize(): Promise<number> {
        let size = 0;
        const files = [FileSystem.attachmentsDir, FileSystem.attachmentCacheDir];

        for (const file of files) {
            if (fs.existsSync(file)) {
                size += await FileSystem.getDirectorySize(file);
            }
        }

        return size;
    }

    static async getDirectorySize(directory: string) {
        const files = await fs.promises.readdir(directory);
        const stats = files.map(file => fs.promises.stat(path.join(directory, file)));
        return (await Promise.all(stats)).reduce((accumulator, { size }) => accumulator + size, 0);
    }

    static async getFiles(dir: string): Promise<string[]> {
        const dirents = await fs.promises.readdir(dir, { withFileTypes: true });
        const files = await Promise.all(
            dirents.map(dirent => {
                const res = path.resolve(dir, dirent.name);
                return dirent.isDirectory() ? FileSystem.getFiles(res) : res;
            })
        );

        return Array.prototype.concat(...files);
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
        if (fs.existsSync(dir)) rimrafSync(dir);
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
    static saveFCMClient(contents: Record<string, any>): void {
        if (FileSystem.usingCustomFcm) {
            Server().log("Not saving FCM client file because custom FCM path is set", "debug");
        }

        if (!fs.existsSync(FileSystem.fcmDir)) fs.mkdirSync(FileSystem.fcmDir);
        const filePath = FileSystem.fcmClientPath;
        if (!contents && fs.existsSync(filePath)) {
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
    static saveFCMServer(contents: Record<string, any>): void {
        if (FileSystem.usingCustomFcm) {
            Server().log("Not saving FCM server file because custom FCM path is set", "debug");
        }

        if (!fs.existsSync(FileSystem.fcmDir)) fs.mkdirSync(FileSystem.fcmDir);
        const filePath = FileSystem.fcmServerPath;
        if (!contents && fs.existsSync(filePath)) {
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
        const filePath = FileSystem.fcmClientPath;
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
        const filePath = FileSystem.fcmServerPath;
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
            fs.unlinkSync(path.join(FileSystem.getAttachmentDirectory(null), name));
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
        const files = fs.readdirSync(FileSystem.getAttachmentDirectory(null));
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
        // If we are managing the messages process, we don't need to make sure it's started
        const papi_enabled = Server().repo.getConfig("enable_private_api") as boolean;
        const papi_mode = Server().repo.getConfig("private_api_mode") as string;
        if (papi_enabled && papi_mode === "process-dylib") return;

        // Start the messages app
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
        if (isEmpty(output)) return output;

        if (output[0] === "~") {
            output = path.join(process.env.HOME, output.slice(1));
        }

        return output;
    }

    static async convertCafToMp3(originalPath: string, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(originalPath);
        const output = await FileSystem.execShellCommand(
            `/usr/bin/afconvert -f m4af -d aac "${oldPath}" "${outputPath}"`
        );
        if (isNotEmpty(output) && output.includes("Error:")) {
            throw Error(`Failed to convert audio to MP3: ${output}`);
        }
    }

    static async convertMp3ToCaf(originalPath: string, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(originalPath);
        const output = await FileSystem.execShellCommand(
            `/usr/bin/afconvert -f caff -d LEI16@44100 -c 1 "${oldPath}" "${outputPath}"`
        );
        if (isNotEmpty(output) && output.includes("Error:")) {
            throw Error(`Failed to convert audio to CAF: ${output}`);
        }
    }

    static async convertToJpg(originalPath: string, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(originalPath);
        const output = await FileSystem.execShellCommand(
            `/usr/bin/sips --setProperty "format" "jpeg" "${oldPath}" --out "${outputPath}"`
        );
        if (isNotEmpty(output) && output.includes("Error:")) {
            throw Error(`Failed to convert image to JPEG: ${output}`);
        }
    }

    static async isSipDisabled(): Promise<boolean> {
        const res = ((await FileSystem.execShellCommand(`csrutil status`)) ?? "").trim();
        return !res.endsWith("enabled.");
    }

    static async hasFullDiskAccess(): Promise<boolean> {
        const res = (
            (await FileSystem.execShellCommand(
                `defaults read ~/Library/Preferences/com.apple.universalaccessAuthWarning.plist`
            )) ?? ""
        ).trim();
        return res.includes('BlueBubbles.app" = 1') || res.includes('BlueBubbles" = 1');
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

    static removeDirectory(filePath: string) {
        rimrafSync(filePath);
    }

    static async getRegion(): Promise<string | null> {
        let region = null;

        try {
            // Try to get the language (i.e. en_US)
            const output = await FileSystem.execShellCommand(
                `defaults read -g AppleLanguages | sed '/"/!d;s/["[:space:]]//g;s/-/_/'`
            );

            // If we get a result back, pull the region out of it
            if (isNotEmpty(output) && output.includes("_")) {
                region = output.split("_")[1].trim();
            }
        } catch (ex) {
            // Don't do anything if it fails, we'll just default to US
        }

        return region;
    }

    static async getIcloudAccount(): Promise<string> {
        let account = null;

        try {
            // Try to get the language (i.e. en_US)
            const output = await FileSystem.execShellCommand(
                `/usr/libexec/PlistBuddy -c "print :Accounts:0:AccountID" ~/Library/Preferences/MobileMeAccounts.plist`
            );

            // If we get a result back, pull the region out of it
            if (isNotEmpty(output) && output.includes("@")) {
                account = output.trim();
            }
        } catch (ex) {
            // Don't do anything if it fails, we'll just default to US
        }

        return account;
    }

    static async getTimeSync(): Promise<number | null> {
        try {
            const output = (await FileSystem.execShellCommand(`sntp time.apple.com`)).trim();
            const matches = output.match(/[+-]?([0-9]*[.])?[0-9]+ \+\/- [+-]?([0-9]*[.])?[0-9]+/g);
            if (matches && matches.length > 0) {
                const time = matches[0].split(" +/- ")[0];
                return Number.parseFloat(time);
            }
        } catch (ex) {
            Server().log("Failed to sync time with time servers!", "debug");
            Server().log(ex, 'debug');
        }

        return null;
    }

    static getLocalIps(type: "IPv4" | "IPv6" = "IPv4"): string[] {
        const interfaces = os.networkInterfaces();
        const addresses = [];
        for (const k in interfaces) {
            for (const k2 in interfaces[k]) {
                const address = interfaces[k][k2];
                if (address.family !== type || address.internal) continue;
                if (address.mac === "00:00:00:00:00:00") continue;
                addresses.push(address.address);
            }
        }

        return addresses;
    }

    static async killProcess(name: string): Promise<void> {
        await FileSystem.execShellCommand(`killall "${name}"`);
    }

    static async processIsRunning(name: string): Promise<boolean> {
        const processes = await FindProcess("name", name);
        return processes.length > 0;
    }

    static async createLaunchAgent(): Promise<void> {
        const appPath = app.getPath("exe");
        const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>AssociatedBundleIdentifiers</key>
        <array>
            <string>com.BlueBubbles.BlueBubbles-Server</string>
        </array>
        <key>Label</key>
        <string>com.bluebubbles.server</string>
        <key>Program</key>
        <string>${appPath}</string>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
	        <key>SuccessfulExit</key>
	        <false/>
            <key>Crashed</key>
            <true/>
	    </dict>
    </dict>
</plist>`;

        const plistName = "com.bluebubbles.server";
        const filePath = path.join(userHomeDir(), "Library", "LaunchAgents", `${plistName}.plist`);
        if (!fs.existsSync(filePath)) {
            fs.writeFileSync(filePath, plist);
        }

        try {
            // Always disable first, which will never error out.
            // Makes a clean slate for enabling then bootstrapping
            await FileSystem.execShellCommand(`launchctl disable gui/${os.userInfo().uid}/${plistName}`);

            // Enable should allow start on boot
            await FileSystem.execShellCommand(`launchctl enable gui/${os.userInfo().uid}/${plistName}`);

            // Bootstrap should load and start the service
            await FileSystem.execShellCommand(`launchctl bootstrap gui/${os.userInfo().uid} "${filePath}"`);
        } catch (ex: any) {
            Server().log(`Failed to create launch agent: ${ex?.message ?? String(ex)}`, "error");
        }
    }

    static async removeLaunchAgent(): Promise<void> {
        const plistName = "com.bluebubbles.server";
        const filePath = path.join(userHomeDir(), "Library", "LaunchAgents", `${plistName}.plist`);

        // Disable should stop the service from starting on boot
        try {
            await FileSystem.execShellCommand(`launchctl disable gui/${os.userInfo().uid}/${plistName}`);
            await FileSystem.execShellCommand(`launchctl bootout gui/${os.userInfo().uid}/${plistName}`);
        } catch (ex: any) {
            Server().log(`Failed to remove launch agent: ${ex?.message ?? String(ex)}`, "error");
        }

        // The shell command requires the path to exist
        if (fs.existsSync(filePath)) {
            fs.unlinkSync(filePath);
        }
    }

    static async lockMacOs(): Promise<void> {
        const pyPath = path.join(FileSystem.resources, "macos", "tools", "lock_screen_immediately.py");
        if (!fs.existsSync(pyPath)) throw Error("Lock screen script not found!");

        await FileSystem.execShellCommand(`python ${pyPath}`);
    }
}
