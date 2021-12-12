import { $, ProcessOutput, ProcessPromise } from "zx";
import * as path from "path";
import { EventEmitter } from "events";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server/index";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";

export class CloudflareManager extends EventEmitter {
    daemonPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflared");

    // Use a default (empty) config file so we don't interfere with the default CF install (if any)
    cfgPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflared-config.yml");

    proc: ProcessPromise<ProcessOutput>;

    currentProxyUrl: string;

    updateFrequencyMs = 86400000; // Default update frequency (24 hrs)

    private proxyUrlRegex = /INF \|\s{1,}(https:\/\/[^\s]+)\s{1,}\|/m;

    async start(): Promise<string> {
        try {
            this.emit("started");
            return this.connectHandler();
        } catch (ex) {
            Server().log(`Failed to run Cloudflare daemon! ${ex.toString()}`, "error");
            this.emit("error", ex);
        }

        return null;
    }

    private async connectHandler(): Promise<string> {
        console.log("hello,my name ches");
        return new Promise((resolve, reject) => {
            const port = Server().repo.getConfig("socket_port") as string;
            this.proc = $`${this.daemonPath} tunnel --url localhost:${port} --config ${this.cfgPath}`;

            // If there is an error with the command, throw the error
            this.proc.catch(reason => {
                reject(reason);
            });

            // Configure handlers for all the output events
            this.proc.stdout.on("data", chunk => this.handleData(chunk));
            this.proc.stdout.on("error", chunk => this.handleError(chunk));
            this.proc.stderr.on("data", chunk => this.handleData(chunk));
            this.proc.stderr.on("error", chunk => this.handleError(chunk));

            this.on("new-url", url => resolve(url));
            this.on("error", err => reject(err));

            setTimeout(() => {
                reject(new Error("Failed to connect to Cloudflare after 30 seconds..."));
            }, 1000 * 30); // 30 seconds
        });
    }

    async stop() {
        if (!this.proc) return;
        this.currentProxyUrl = null;
        await this.proc.kill();
    }

    setProxyUrl(url: string) {
        if (isEmpty(url) || !url.startsWith("https://") || url === this.currentProxyUrl) return;
        Server().log(`Setting Cloudflare Proxy URL: ${url}`);
        this.currentProxyUrl = url;
        this.emit("new-url", this.currentProxyUrl);
    }

    setUpdateFrequency(value: string) {
        if (isEmpty(value)) return;

        try {
            this.updateFrequencyMs = Number.parseInt(value.trim(), 10);
            this.emit("new-frequency", this.updateFrequencyMs);
        } catch (ex) {
            // Don't do anything (probably a parsing issue)
        }
    }

    handleData(chunk: any) {
        const data: string = chunk.toString();
        const urlMatches = data.match(this.proxyUrlRegex);
        if (isNotEmpty(urlMatches)) this.setProxyUrl(urlMatches[1]);
        if (data.startsWith("Autoupdate frequency is set autoupdateFreq=")) {
            this.setUpdateFrequency(data.split("=")[1]);
        } else if (data.includes("connect: bad file descriptor")) {
            Server().log("Failed to connect to Cloudflare's servers! Please make sure your Mac is up to date", "warn");
        }
    }

    handleError(chunk: any) {
        this.emit("error", chunk);
    }
}
