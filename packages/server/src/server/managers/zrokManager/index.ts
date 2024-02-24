import { isNotEmpty, isEmpty } from "@server/helpers/utils";
import { Loggable, getLogger } from "@server/lib/logging/Loggable";
import { FileSystem } from "@server/fileSystem";
import axios from "axios";
import { app } from "electron";
import { Server } from "@server";
import { ProcessOutput } from "zx";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";

export class ZrokManager extends Loggable {
    tag = "ZrokManager";

    static get daemonPath() {
        return path.join(FileSystem.resources, "macos", "daemons", "zrok", "zrok");
    }

    proc: ChildProcessWithoutNullStreams;

    currentProxyUrl: string;

    isRestarting = false;

    private proxyUrlRegex = /\b(https:\/\/.*?\.zrok.io)\b/m;

    async start(): Promise<string> {
        try {
            this.emit("started");
            return this.connectHandler();
        } catch (ex) {
            this.log.error(`Failed to run Zrok daemon! ${ex.toString()}`);
            this.emit("error", ex);
        }

        return null;
    }

    private async connectHandler(): Promise<string> {
        return new Promise((resolve, reject) => {
            const port = Server().repo.getConfig("socket_port") as string;

            // Didn't use zx here because I couldn't figure out how to pipe the stdout
            // properly, without taking over the terminal outputs.
            this.proc = spawn(ZrokManager.daemonPath, [
                "share",
                "public",
                "--backend-mode",
                "proxy",
                `0.0.0.0:${port}`
            ]);
            this.proc.stdout.on("data", chunk => this.handleData(chunk));
            this.proc.stderr.on("data", chunk => this.handleData(chunk));

            this.on("new-url", url => resolve(url));
            this.on("error", err => reject(err));

            setTimeout(() => {
                reject(new Error("Failed to connect to Zrok after 2 minutes..."));
            }, 1000 * 60 * 2); // 2 minutes
        });
    }

    async stop() {
        if (!this.proc) return;
        this.currentProxyUrl = null;
        await this.proc.kill();
    }

    setProxyUrl(url: string) {
        if (isEmpty(url) || !url.startsWith("https://") || url === this.currentProxyUrl) return;
        this.log.info(`Setting Zrok Proxy URL: ${url}`);
        this.currentProxyUrl = url;
        this.emit("new-url", this.currentProxyUrl);
    }

    async handleData(chunk: any) {
        const data: string = chunk.toString();
        if (data.includes("dial tcp: lookup api.zrok.io")) {
            this.handleError("Failed to connect to Zrok's servers! Please make sure you're connected to the internet.");
            return;
        } else if (data.includes("[ERROR]")) {
            this.handleError(data.substring(data.indexOf("[ERROR]")));
            return;
        }

        this.detectNewUrl(data);
    }

    private detectNewUrl(data: string) {
        const urlMatches = data.match(this.proxyUrlRegex);
        if (isNotEmpty(urlMatches)) this.setProxyUrl(urlMatches[0]);
    }

    handleError(chunk: any) {
        this.emit("error", chunk);
    }

    static async getInvite(email: string): Promise<void> {
        try {
            // Use axios to get the invite with the following spec
            await axios.post("https://api.zrok.io/api/v1/invite", JSON.stringify({ email }), {
                headers: {
                    "Content-Type": "application/zrok.v1+json",
                    Accept: "application/zrok.v1+json",
                    "User-Agent": `BlueBubbles Server/${app.getVersion()}`,
                    "Accept-Encoding": "gzip",
                    Host: "api.zrok.io"
                }
            });
        } catch (ex: any) {
            const data = ex?.response?.data;
            if (isEmpty(data)) {
                throw new Error(`Failed to dispatch Zrok invite! Please check your email address and try again.`);
            } else if (data.includes("duplicate")) {
                throw new Error("This email is already registered with Zrok!");
            }

            throw new Error(data);
        }
    }

    static async setToken(token: string): Promise<ProcessOutput> {
        try {
            return await $`${this.daemonPath} enable ${token}`;
        } catch (ex: any | ProcessOutput) {
            if (ex.stderr) {
                if (ex.stderr.includes("you already have an enabled environment")) {
                    return ex;
                }

                throw new Error(ex.stderr.trim());
            }

            const err = ex.stdout;
            if (err.includes("enableUnauthorized")) {
                throw new Error("Invalid Zrok token!");
            } else {
                const logger = getLogger("ZrokManager");
                logger.error(`Failed to set Zrok token! Error: ${err}`);
                throw new Error("Failed to set Zrok token! Please check your server logs for more information.");
            }
        }
    }

    static async disable(token: string): Promise<ProcessOutput> {
        return await $`${this.daemonPath} disable`;
    }
}
