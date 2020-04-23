import * as fs from "fs";
import * as path from "path";
import { app } from "electron";
import * as child_process from "child_process";

import { AppleScripts } from "./scripts";

export class FileSystem {
    public scriptDir = `${app.getPath("userData")}/Scripts`;

    public attachmentsDir = `${app.getPath("userData")}/Attachments`;

    async setup() {
        this.setupDirectories();
        this.setupScripts();
    }

    setupDirectories() {
        if (!fs.existsSync(this.scriptDir)) fs.mkdirSync(this.scriptDir);
        if (!fs.existsSync(this.attachmentsDir))
            fs.mkdirSync(this.attachmentsDir);
    }

    setupScripts() {
        AppleScripts.forEach((script) => {
            // Remove each script, and re-write it (in case of update)
            const scriptPath = `${this.scriptDir}/${script.name}`;
            if (fs.existsSync(scriptPath)) fs.unlinkSync(scriptPath);
            fs.writeFileSync(scriptPath, script.contents);
        });
    }

    saveAttachment(name: string, buffer: Buffer) {
        fs.writeFileSync(path.join(this.attachmentsDir, name), buffer);
    }

    removeAttachment(name: string) {
        try {
            fs.unlinkSync(path.join(this.attachmentsDir, name));
        } catch (e) {
            console.warn(`Failed to remove attachment: ${name}`);
        }
    }

    purgeAttachments() {
        const files = fs.readdirSync(this.attachmentsDir);
        files.forEach(file => {
            this.removeAttachment(file);
        });
    }

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