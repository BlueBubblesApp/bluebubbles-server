import * as fs from "fs";
import * as path from "path";
import { app } from "electron";
import * as child_process from "child_process";
import { sync } from "read-chunk";
import { AppleScripts } from "./scripts";

/**
 * The class used to handle all communications to the App's "filesystem".
 * The filesystem is the directory dedicated to the app-specific files
 */
export class FileSystem {
    public scriptDir = `${app.getPath("userData")}/Scripts`;

    public attachmentsDir = `${app.getPath("userData")}/Attachments`;

    public fcmDir = `${app.getPath("userData")}/FCM`;

    /**
     * Sets up all required directories and then, writes the scripts
     * to the scripts directory
     */
    async setup(): Promise<void> {
        this.setupDirectories();
        this.setupScripts();
    }

    /**
     * Creates required directories
     */
    setupDirectories(): void {
        if (!fs.existsSync(this.scriptDir)) fs.mkdirSync(this.scriptDir);
        if (!fs.existsSync(this.attachmentsDir)) fs.mkdirSync(this.attachmentsDir);
        if (!fs.existsSync(this.fcmDir))fs.mkdirSync(this.fcmDir);
    }

    /**
     * Creates required scripts
     */
    setupScripts(): void {
        AppleScripts.forEach((script) => {
            // Remove each script, and re-write it (in case of update)
            const scriptPath = `${this.scriptDir}/${script.name}`;
            if (fs.existsSync(scriptPath)) fs.unlinkSync(scriptPath);
            fs.writeFileSync(scriptPath, script.contents);
        });
    }

    /**
     * Saves an attachment
     *
     * @param name Name for the attachment
     * @param buffer The attachment bytes (buffer)
     */
    saveAttachment(name: string, buffer: Buffer): void {
        fs.writeFileSync(path.join(this.attachmentsDir, name), buffer);
    }

    /**
     * Saves the Client FCM JSON file
     *
     * @param contents The object data for the FCM client
     */
    saveFCMClient(contents: any): void {
        fs.writeFileSync(path.join(this.fcmDir, "client.json"), JSON.stringify(contents));
    }

    /**
     * Saves the Server FCM JSON file
     *
     * @param contents The object data for the FCM server
     */
    saveFCMServer(contents: any): void {
        fs.writeFileSync(path.join(this.fcmDir, "server.json"), JSON.stringify(contents));
    }

    /**
     * Gets the FCM client data
     * 
     * @returns The parsed FCM client data
     */
    getFCMClient(): any {
        const filePath = path.join(this.fcmDir, "client.json");
        if (!fs.existsSync(filePath)) return null;

        return JSON.parse(fs.readFileSync(filePath, "utf8"));
    }

    /**
     * Gets the FCM server data
     * 
     * @returns The parsed FCM server data
     */
    getFCMServer(): any {
        const filePath = path.join(this.fcmDir, "server.json");
        if (!fs.existsSync(filePath)) return null;

        return JSON.parse(fs.readFileSync(filePath, "utf8"));
    }

    /**
     * Deletes an attachment from the app's image cache
     *
     * @param name The name of the attachment to delete
     */
    removeAttachment(name: string): void {
        try {
            fs.unlinkSync(path.join(this.attachmentsDir, name));
        } catch (e) {
            console.warn(`Failed to remove attachment: ${name}`);
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
    purgeAttachments(): void {
        const files = fs.readdirSync(this.attachmentsDir);
        files.forEach(file => {
            this.removeAttachment(file);
        });
    }

    /**
     * Asynchronously executes a shell command
     */
    execShellCommand = async (cmd: string) => {
        const { exec } = child_process;
        return new Promise((resolve, reject) => {
            exec(cmd, (error, stdout, stderr) => {
                if (error) {
                    reject(error);
                }

                resolve(stdout || stderr);
            });
        });
    };
}