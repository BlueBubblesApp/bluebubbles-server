import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import * as child_process from "child_process";
import { transports } from "electron-log";
import { app } from "electron";
import { sync } from "read-chunk";
import { Server } from "@server";
import {
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
import { v4 as uuidv4 } from "uuid";

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

    // Chunked uploads get their own directory, so a client-chosen GUID can never name
    // (and later recursively delete) the cache or another send's folder
    public static attachmentChunksDir = path.join(FileSystem.baseDir, "Attachments", "Chunks");

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
        if (!fs.existsSync(FileSystem.attachmentChunksDir)) fs.mkdirSync(FileSystem.attachmentChunksDir);
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

    /**
     * Reduces a value to a single path component, so it can't point outside of the
     * directory it's joined onto. Attachment GUIDs and transfer names come from the
     * sender's device, so they're never trusted as paths.
     *
     * @param value The value to reduce
     * @param fallback What to use when nothing safe is left
     */
    static toPathComponent(value: string, fallback: string): string {
        const name = path.basename(String(value ?? "").replace(/\0/g, ""));
        if (name.length === 0 || name === "." || name === "..") return fallback;
        return name;
    }

    private static attachmentCacheDirFor(attachment: Attachment) {
        const guid = FileSystem.toPathComponent(attachment.originalGuid ?? attachment.guid, "unknown");
        return path.join(FileSystem.attachmentCacheDir, guid);
    }

    static cachedAttachmentPath(attachment: Attachment, name: string) {
        return path.join(FileSystem.attachmentCacheDirFor(attachment), FileSystem.toPathComponent(name, "attachment"));
    }

    static cachedAttachmentExists(attachment: Attachment, name: string) {
        const basePath = this.cachedAttachmentPath(attachment, name);
        return fs.existsSync(basePath);
    }

    static saveCachedAttachment(attachment: Attachment, name: string, data: Buffer) {
        const basePath = FileSystem.attachmentCacheDirFor(attachment);
        if (!fs.existsSync(basePath)) {
            fs.mkdirSync(basePath, { recursive: true });
        }

        fs.writeFileSync(FileSystem.cachedAttachmentPath(attachment, name), data);
    }

    /**
     * Checks that a client-supplied name is a single, plain path component.
     * Anything containing a path separator, a null byte, or that is "." / ".."
     * could be used to escape the directory it is joined onto.
     *
     * @param name The name to check
     */
    static isSafeFileName(name: any): boolean {
        if (typeof name !== "string" || isEmpty(name)) return false;
        if (name === "." || name === "..") return false;
        return !/[/\\\0]/.test(name);
    }

    /**
     * Returns the name if it is safe to use as a file/folder name, otherwise throws
     *
     * @param name The name to check
     */
    static sanitizeFileName(name: any): string {
        if (!FileSystem.isSafeFileName(name)) {
            throw new Error(`Invalid file name: "${name}"`);
        }

        return name;
    }

    /**
     * Resolves path segments against a base directory, and throws if the
     * resulting path would land outside of that directory.
     *
     * @param baseDir The directory the path must stay within
     * @param segments The path segments to resolve
     */
    static resolveWithin(baseDir: string, ...segments: string[]): string {
        const base = path.resolve(baseDir);
        const resolved = path.resolve(base, ...segments);
        if (resolved !== base && !resolved.startsWith(base + path.sep)) {
            throw new Error(`Invalid path: "${path.join(...segments)}" is outside of the allowed directory`);
        }

        return resolved;
    }

    /**
     * Saves an attachment
     *
     * @param name Name for the attachment
     * @param buffer The attachment bytes (buffer)
     */
    static saveAttachment(name: string, buffer: Uint8Array): string {
        const dir = FileSystem.getAttachmentDirectory(null);
        const newFile = FileSystem.resolveWithin(dir, FileSystem.sanitizeFileName(name));
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
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
        const newPath = FileSystem.resolveWithin(dir, guid, FileSystem.sanitizeFileName(name));
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

        const parent = path.dirname(newPath);
        if (!fs.existsSync(parent)) fs.mkdirSync(parent, { recursive: true });

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
        const index = Number(chunkNumber);
        if (!Number.isInteger(index) || index < 0) throw new Error(`Invalid chunk number: "${chunkNumber}"`);

        const parent = FileSystem.getChunkDirectory(guid);
        if (!fs.existsSync(parent)) fs.mkdirSync(parent, { recursive: true });
        fs.writeFileSync(path.join(parent, `${index}.chunk`), buffer);
    }

    /**
     * Returns the directory that holds the chunks for an attachment.
     *
     * The GUID comes from the client and every chunk function writes, reads, or
     * recursively deletes this directory, so it must be a single plain path
     * component that stays inside the chunks directory (and is not that directory).
     *
     * @param guid Unique identifier for the attachment
     */
    private static getChunkDirectory(guid: string): string {
        const dir = FileSystem.resolveWithin(FileSystem.attachmentChunksDir, FileSystem.sanitizeFileName(guid));
        if (dir === path.resolve(FileSystem.attachmentChunksDir)) throw new Error(`Invalid attachment GUID: "${guid}"`);
        return dir;
    }

    static readonly maxLogLines = 10000;

    /**
     * Parses a client-supplied log line count. Returns the default when the value is
     * absent, null when it is not a positive integer, and caps it at maxLogLines.
     */
    static parseLogCount(value: any, defaultCount = 100): number | null {
        if (value === undefined || value === null || value === "") return defaultCount;
        if (typeof value !== "number" && typeof value !== "string") return null;
        if (typeof value === "string" && !/^\d+$/.test(value.trim())) return null;

        const count = Number(value);
        if (!Number.isInteger(count) || count < 1) return null;
        return Math.min(count, FileSystem.maxLogLines);
    }

    static getLogs({ count = 100 }): Promise<string> {
        const fPath = transports.file.getFile().path;
        return FileSystem.readLastLines({
            filePath: fPath,
            count
        });
    }

    private static async readLastLines({
        filePath,
        count = 100
    }: {
        filePath: string;
        count?: number;
    }): Promise<string> {
        const lines = FileSystem.parseLogCount(count);
        if (lines === null) {
            throw new Error("Invalid log line count: must be a positive integer");
        }

        // Read the file directly rather than shelling out to `tail`, so the client-supplied
        // count never reaches a command line. The log is rotated at 1MB, so this stays small.
        const content = await fs.promises.readFile(filePath, "utf8");
        const all = content.split("\n");
        if (all.length > 0 && all[all.length - 1] === "") all.pop();
        return all.length > 0 ? `${all.slice(-lines).join("\n")}\n` : "";
    }

    /**
     * Removes a chunk directory
     *
     * @param guid Unique identifier for the attachment
     */
    static deleteChunks(guid: string): void {
        let dir: string;
        try {
            dir = FileSystem.getChunkDirectory(guid);
        } catch {
            // Never recursively delete anything outside of the attachments directory.
            // This runs from the queue's cleanup timer, where a throw would be uncaught.
            return;
        }

        if (fs.existsSync(dir)) rimrafSync(dir);
    }

    /**
     * Builds an attachment by combining all chunks
     *
     * @param guid Unique identifier for the attachment
     */
    static buildAttachmentChunks(guid: string, name: string): string {
        let chunks = new Uint8Array(0);
        const dir = FileSystem.getChunkDirectory(guid);
        const outFile = FileSystem.resolveWithin(dir, FileSystem.sanitizeFileName(name));

        // Get the chunk files in ascending order (only the ones we wrote)
        const files = fs.readdirSync(dir).filter(file => /^\d+\.chunk$/.test(file));
        files.sort((a, b) => Number(a.split(".")[0]) - Number(b.split(".")[0]));

        // Read the files and append to chunks
        for (const file of files) {
            const fileData = fs.readFileSync(path.join(dir, file));
            chunks = concatUint8Arrays(chunks, Uint8Array.from(fileData));
        }

        // Write the final file to disk
        fs.writeFileSync(outFile, chunks);

        return outFile;
    }

    /**
     * Saves a VCF file
     *
     * @param vcf The VCF data to save
     */
    static saveVCF(vcf: string): void {
        // Validate before deleting anything, so bad input can't leave the contacts file missing
        if (typeof vcf !== "string") {
            throw new Error("VCF data must be a string");
        }

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

    static readonly maxFileChunkSize = 16 * 1024 * 1024; // 16MB

    static readFileChunk(filePath: string, start: number, chunkSize = 1024): Uint8Array {
        // The size is allocated up-front, so it must be bounded
        if (!Number.isInteger(chunkSize) || chunkSize < 1) {
            throw new Error("Invalid chunk size: must be a positive integer");
        }
        if (!Number.isInteger(start) || start < 0) {
            throw new Error("Invalid chunk start: must be a non-negative integer");
        }

        const size = Math.min(chunkSize, FileSystem.maxFileChunkSize);

        // Get the file size
        const stats = fs.statSync(filePath);
        let fStart = start;

        // Make sure the start are not bigger than the size
        if (fStart > stats.size) fStart = stats.size;
        return Uint8Array.from(sync(filePath, fStart, size));
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

    /**
     * Asynchronously executes a program with an argument list (no shell)
     */
    static async execFileCommand(file: string, args: string[]): Promise<string> {
        const { execFile } = child_process;
        return new Promise((resolve, reject) => {
            execFile(file, args, (error, stdout, stderr) => {
                if (error) {
                    reject(error);
                }

                resolve(stdout || stderr);
            });
        });
    }

    static async executeAppleScript(cmd: string) {
        if (isEmpty(cmd)) return null;

        // Each line is its own argument to osascript, never a shell string,
        // so nothing in the script can be interpreted by /bin/sh
        const args = cmd
            .split("\n")
            .map(i => safeTrim(i))
            .filter(i => isNotEmpty(i))
            .flatMap(i => ["-e", i]);

        return FileSystem.execFileCommand("/usr/bin/osascript", args);
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

        // Converted files are cached by path, so a truncated output would be served forever.
        // afconvert happily "succeeds" on a CAF that is still being written, so convert into
        // a temporary file and only publish it if the source did not change underneath us.
        // The name is unique per call: the same attachment is often converted by several requests at once.
        const tmpPath = `${outputPath}.${uuidv4()}.partial`;
        const before = fs.statSync(oldPath);
        try {
            // Attachment file names come from whoever sent the message, so they must
            // never pass through a shell (where $(...) and backticks would execute)
            const output = await FileSystem.execFileCommand("/usr/bin/afconvert", [
                "-f",
                "m4af",
                "-d",
                "aac",
                oldPath,
                tmpPath
            ]);
            if (isNotEmpty(output) && output.includes("Error:")) {
                throw Error(`Failed to convert audio to MP3: ${output}`);
            }

            const after = fs.statSync(oldPath);
            if (after.size !== before.size || after.mtimeMs !== before.mtimeMs) {
                throw Error("Failed to convert audio to MP3: the source file changed during conversion");
            }

            fs.renameSync(tmpPath, outputPath);
        } finally {
            if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
        }
    }

    static async isOpusCaf(filePath: string): Promise<boolean> {
        try {
            const output = await FileSystem.execFileCommand("/usr/bin/afinfo", [FileSystem.getRealPath(filePath)]);
            return /Data format:.*\bopus\b/i.test(output ?? "");
        } catch {
            return false;
        }
    }

    /**
     * Messages only renders a native voice memo (waveform + real duration) for the format it
     * records itself: Opus, 24 kHz, mono, in a CAF container. A PCM CAF shows a 0s bubble.
     * Older macOS releases may lack the Opus encoder, so fall back to the previous PCM recipe.
     */
    static async convertToVoiceMemoCaf(originalPath: string, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(originalPath);
        const recipes = [
            ["-d", "opus@24000", "-c", "1"],
            ["-d", "LEI16@44100", "-c", "1"]
        ];

        let lastError: any = null;
        for (const recipe of recipes) {
            try {
                const output = await FileSystem.execFileCommand("/usr/bin/afconvert", [
                    "-f",
                    "caff",
                    ...recipe,
                    oldPath,
                    outputPath
                ]);
                if (isNotEmpty(output) && output.includes("Error:")) {
                    throw Error(output);
                }

                return;
            } catch (ex: any) {
                lastError = ex;
                if (fs.existsSync(outputPath)) fs.unlinkSync(outputPath);
            }
        }

        throw Error(`Failed to convert audio to CAF: ${lastError?.message ?? lastError}`);
    }

    /**
     * Prepares a file that is about to be sent as an audio message. MP3s are transcoded to a
     * CAF next to the original (the message awaiter expects the `.caf` name); CAFs that are
     * not already Opus are re-encoded in place, keeping their name. Never throws: on failure
     * the original path is returned and the file is sent as-is.
     */
    static async prepareVoiceMemo(filePath: string): Promise<string> {
        const ext = path.extname(filePath).toLowerCase();

        try {
            if (ext === ".mp3") {
                const newPath = `${filePath.substring(0, filePath.length - 4)}.caf`;
                await FileSystem.convertToVoiceMemoCaf(filePath, newPath);
                return newPath;
            }

            if (ext === ".caf" && !(await FileSystem.isOpusCaf(filePath))) {
                const tmpPath = path.join(path.dirname(filePath), `${uuidv4()}.caf`);
                await FileSystem.convertToVoiceMemoCaf(filePath, tmpPath);
                fs.renameSync(tmpPath, filePath);
            }
        } catch (ex: any) {
            Server().log(`Failed to prepare voice memo, sending the original file: ${ex?.message ?? ex}`, "warn");
        }

        return filePath;
    }

    static async convertToJpg(originalPath: string, outputPath: string): Promise<void> {
        const oldPath = FileSystem.getRealPath(originalPath);
        const output = await FileSystem.execFileCommand("/usr/bin/sips", [
            "--setProperty",
            "format",
            "jpeg",
            oldPath,
            "--out",
            outputPath
        ]);
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
            return parseMetadataString(
                await FileSystem.execFileCommand("/usr/bin/mdls", [FileSystem.getRealPath(filePath)])
            );
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
        await FileSystem.execFileCommand("/usr/bin/killall", [name]);
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

        // No shell, so a resources path containing spaces still resolves to one argument
        await FileSystem.execFileCommand("python", [pyPath]);
    }
}
