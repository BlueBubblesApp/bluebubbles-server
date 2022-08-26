import { $, ProcessOutput, ProcessPromise } from "zx";
import * as path from "path";
import { EventEmitter } from "events";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";

export class CloudflareManager extends EventEmitter {
    daemonPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflared");

    // Use a default (empty) config file so we don't interfere with the default CF install (if any)
    cfgPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflared-config.yml");

    pidPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflare.pid");

    proc: ProcessPromise<ProcessOutput>;

    currentProxyUrl: string;

    isRestarting = false;

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
        return new Promise((resolve, reject) => {
            const port = Server().repo.getConfig("socket_port") as string;
            // eslint-disable-next-line max-len
            this.proc = $`${this.daemonPath} tunnel --url localhost:${port} --config ${this.cfgPath} --pidfile ${this.pidPath}`;

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
            this.on("error", err => {
                // Ignore certain errors
                if (typeof err === "string") {
                    if (err.includes('Thank you for trying Cloudflare Tunnel.')) return;
                }

                reject(err)
            });

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

    async handleData(chunk: any) {
        const data: string = chunk.toString();
        if (data.includes("connect: bad file descriptor")) {
            Server().log("Failed to connect to Cloudflare's servers! Please make sure your Mac is up to date", "debug");
            return;
        }

        this.detectNewUrl(data);
        this.detectMaxConnectionRetries(data);
    }

    private detectNewUrl(data: string) {
        const urlMatches = data.match(this.proxyUrlRegex);
        if (isNotEmpty(urlMatches)) this.setProxyUrl(urlMatches[1]);
    }

    private detectMaxConnectionRetries(data: string) {
        if (this.isRestarting) return;
        if (data.includes("Retrying connection in up to ")) {
            try {
                const splitData = data.split("Retrying connection in up to ")[1];
                const secSplit = splitData.split(" ")[0].replace("s", "").trim();

                // Cloudflare will retry every 1, 2, 4, 8, and 16 seconds (when retry count if 5, by default)
                const retrySec = Number.parseInt(secSplit, 10);
                if (!isNaN(retrySec)) {
                    Server().log(`Detected Cloudflare retry in ${retrySec} seconds...`, "debug");
                    if (retrySec >= 16) {
                        this.isRestarting = true;

                        Server().log(
                            "Cloudflare reached its max connection retries. Restarting proxy service...",
                            "debug"
                        );
                        this.emit("needs-restart", true);
                    }
                }
            } catch (ex) {
                // Don't do anything
            }
        }
    }

    handleError(chunk: any) {
        this.emit("error", chunk);
    }
}
