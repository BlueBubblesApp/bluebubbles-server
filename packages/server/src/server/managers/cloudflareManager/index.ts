import * as path from "path";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { Loggable } from "@server/lib/logging/Loggable";
import { ChildProcess, spawn } from "child_process";

export class CloudflareManager extends Loggable {
    tag = "CloudflareManager";

    daemonPath = path.join(
        FileSystem.resources, "macos", "daemons", "cloudflare", (process.arch === "arm64") ? "arm64" : "x86", "cloudflared");

    // Use a default (empty) config file so we don't interfere with the default CF install (if any)
    cfgPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflare", "cloudflared-config.yml");

    pidPath = path.join(FileSystem.resources, "macos", "daemons", "cloudflare", "cloudflare.pid");

    proc: ChildProcess;

    currentProxyUrl: string;

    isRestarting = false;

    private proxyUrlRegex = /INF \|\s{1,}(https:\/\/[^\s]+)\s{1,}\|/m;

    async start(): Promise<string> {
        try {
            this.emit("started");
            return this.connectHandler();
        } catch (ex) {
            this.log.error(`Failed to run Cloudflare daemon! ${ex.toString()}`);
            this.emit("error", ex);
        }

        return null;
    }

    private async connectHandler(): Promise<string> {
        return new Promise((resolve, reject) => {
            try {
                const port = Server().repo.getConfig("socket_port") as string;
                this.proc = spawn(this.daemonPath, [
                    'tunnel',
                    '--url', `localhost:${port}`,
                    '--config', this.cfgPath,
                    '--pidfile', this.pidPath
                ]);

                // Configure handlers for all the output events
                this.proc.stdout.on("data", chunk => this.handleData(chunk));
                this.proc.stdout.on("error", chunk => this.handleError(chunk));
                this.proc.stderr.on("data", chunk => this.handleData(chunk));
                this.proc.stderr.on("error", chunk => this.handleError(chunk));

                this.on("new-url", url => resolve(url));
                this.on("error", err => {
                    // Ignore certain errors
                    if (typeof err === "string") {
                        if (err.includes("Thank you for trying Cloudflare Tunnel.")) return;
                    }

                    reject(err);
                });

                setTimeout(() => {
                    reject(new Error("Failed to connect to Cloudflare after 2 minutes..."));
                }, 1000 * 60 * 2); // 2 minutes
            } catch (ex) {
                reject(ex);
            }
        });
    }

    async stop() {
        if (!this.proc) return;
        this.currentProxyUrl = null;
        await this.proc.kill();
    }

    setProxyUrl(url: string) {
        if (isEmpty(url) || !url.startsWith("https://") || url === this.currentProxyUrl) return;
        this.log.info(`Setting Cloudflare Proxy URL: ${url}`);
        this.currentProxyUrl = url;
        this.emit("new-url", this.currentProxyUrl);
    }

    async handleData(chunk: any) {
        const data: string = chunk.toString();
        if (data.includes("connect: bad file descriptor")) {
            this.log.debug("Failed to connect to Cloudflare's servers! Please make sure your Mac is up to date");
            return;
        }

        const error = this.detectError(data);
        if (error) this.emitError(error);

        this.detectNewUrl(data);
        this.detectMaxConnectionRetries(data);
    }

    private detectError(data: string): string | null {
        if (data.includes('no such host')) {
            return 'Unable to resolve api.trycloudflare.com! Ensure that your Mac has internet access and that any networking tools you use are not blocking the hostname.';
        } else if (data.includes('failed to request quick Tunnel: ')) {
            return data.split('failed to request quick Tunnel: ')[1];
        }

        return null;
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

                // Cloudflare will retry every 1, 2, 4, 8, and 16 seconds (when retry count is 5, by default)
                // The retry count is set to 6, so it goes: 1, 2, 4, 8, 16, 32
                const retrySec = Number.parseInt(secSplit, 10);
                if (!isNaN(retrySec)) {
                    this.log.debug(`Detected Cloudflare retry in ${retrySec} seconds...`);
                    if (retrySec >= 32) {
                        this.isRestarting = true;

                        this.log.debug("Cloudflare reached its max connection retries. Restarting proxy service...");
                        this.emit("needs-restart", true);
                    }
                }
            } catch (ex) {
                // Don't do anything
            }
        }
    }

    handleError(chunk: any) {
        const error = this.detectError(chunk);
        if (error) this.emitError(error);
    }

    emitError(err: any) {
        this.emit("error", err);
    }
}
