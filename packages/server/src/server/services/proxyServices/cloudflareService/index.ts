import { CloudflareManager } from "@server/managers/cloudflareManager";
import { Proxy } from "../proxy";

export class CloudflareService extends Proxy {
    tag = "CloudflareService";

    manager: CloudflareManager;

    connectPromise: Promise<string>;

    lastError: string;

    constructor() {
        super({
            name: "Cloudflare",
            autoRefresh: false
        });
    }

    /**
     * Helper for checking if we are connected
     */
    isConnected(): boolean {
        return this.url !== null;
    }

    async checkForError(log: string, _: any = null): Promise<boolean> {
        return this.lastError === log;
    }

    async shouldRelaunch(): Promise<boolean> {
        return !this.manager?.isRateLimited;
    }

    /**
     * Sets up a connection to the Cloudflare servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connect(): Promise<string> {
        if (this.connectPromise) {
            this.log.debug("Already connecting to Cloudflare. Waiting for connection to complete.");
            await this.connectPromise;
        }

        try {
            this.connectPromise = this._connect();
            this.url = await this.connectPromise;
            this.connectPromise = null;
            return this.url;
        } catch (ex: any) {
            this.connectPromise = null;
            this.log.info(`Failed to connect to Cloudflare! Error: ${ex.toString()}`);
            throw ex;
        }
    }

    async _connect(): Promise<string> {
        // Create the connection
        if (!this.manager) {
            this.manager = new CloudflareManager();
        }

        // When we get a new URL, set the URL and update
        this.manager.on("new-url", async url => {
            this.url = url;

            // 5 second delay to allow DNS records to update
            setTimeout(() => {
                this.applyAddress(this.url);
            }, 5000);
        });

        this.manager.on("needs-restart", async _ => {
            try {
                await this.restart();
            } catch (ex) {
                // Don't do anything
            } finally {
                this.manager.isRestarting = false;
            }
        });

        this.url = await this.manager.start();
        return this.url;
    }

    /**
     * Disconnect from Cloudflare
     */
    async disconnect(): Promise<void> {
        if (this.connectPromise) {
            this.connectPromise = null;
        }

        try {
            if (this.manager) {
                this.manager.removeAllListeners();
                await this.manager.stop();
            }
        } finally {
            this.url = null;
        }
    }
}
