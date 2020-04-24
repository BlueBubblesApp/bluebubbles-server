import * as fs from "fs";
import * as path from "path";
import { app } from "electron";
import * as child_process from "child_process";

import { AppleScripts } from "./scripts";

export class FileSystem {
    public scriptDir = `${app.getPath("userData")}/Scripts`;

    public attachmentsDir = `${app.getPath("userData")}/Attachments`;

    public fcmDir = `${app.getPath("userData")}/FCM`;

    async setup(): Promise<void> {
        this.setupDirectories();
        this.setupScripts();
    }

    setupDirectories(): void {
        if (!fs.existsSync(this.scriptDir)) fs.mkdirSync(this.scriptDir);
        if (!fs.existsSync(this.attachmentsDir)) fs.mkdirSync(this.attachmentsDir);
        if (!fs.existsSync(this.fcmDir)) fs.mkdirSync(this.fcmDir);
    }

    setupScripts(): void {
        AppleScripts.forEach((script) => {
            // Remove each script, and re-write it (in case of update)
            const scriptPath = `${this.scriptDir}/${script.name}`;
            if (fs.existsSync(scriptPath)) fs.unlinkSync(scriptPath);
            fs.writeFileSync(scriptPath, script.contents);
        });
    }

    saveAttachment(name: string, buffer: Buffer): void {
        fs.writeFileSync(path.join(this.attachmentsDir, name), buffer);
    }

    saveFCMClient(contents: any): void {
        fs.writeFileSync(path.join(this.fcmDir, "client.json"), JSON.stringify(contents));
    }

    saveFCMServer(contents: any): void {
        fs.writeFileSync(path.join(this.fcmDir, "server.json"), JSON.stringify(contents));
    }

    getFCMClient(): any {
        const filePath = path.join(this.fcmDir, "client.json");
        if (!fs.existsSync(filePath)) return null;

        //Sorry zach, I've literally never touched typescript so you can fix this later, I just want a basic implementation

        var jsonData = JSON.parse(fs.readFileSync(filePath, "utf8"));
        var arrData = [];
        arrData.push(jsonData.project_info.project_id);
        arrData.push(jsonData.project_info.storage_bucket);
        arrData.push(jsonData.client[0].api_key[0].current_key);
        arrData.push(jsonData.project_info.firebase_url);
        var client_id = jsonData.client[0].oauth_client[0].client_id;
        arrData.push(client_id.substr(0, client_id.indexOf('-')));
        arrData.push(jsonData.client[0].client_info.mobilesdk_app_id);


        console.log(arrData.toString());
        return arrData;
    }

    getFCMServer(): any {
        const filePath = path.join(this.fcmDir, "server.json");
        if (!fs.existsSync(filePath)) return null;

        return JSON.parse(fs.readFileSync(filePath, "utf8"));
    }

    removeAttachment(name: string): void {
        try {
            fs.unlinkSync(path.join(this.attachmentsDir, name));
        } catch (e) {
            console.warn(`Failed to remove attachment: ${name}`);
        }
    }

    purgeAttachments(): void {
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