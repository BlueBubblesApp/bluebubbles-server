import { CloudflareManager } from "@server/managers/cloudflareManager";
import { Proxy } from "../proxy";

export class CloudflareService extends Proxy {
    manager: CloudflareManager;

    constructor() {
        super({
            name: "Cloudflare",
            refreshTimerMs: 86400000, // 24 hours
            autoRefresh: true
        });
    }

    /**
     * Helper for checking if we are connected
     */
    isConnected(): boolean {
        return this.url !== null;
    }

    /**
     * Sets up a connection to the LocalTunnel servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connect(): Promise<string> {
        // Create the connection
        this.manager = new CloudflareManager();

        // When we get a new URL, set the URL and update
        this.manager.on("new-url", async url => {
            if (url === this.url) return;

            this.url = url;

            // 3 second delay to allow DNS records to update
            setTimeout(() => {
                this.applyAddress(this.url);
            }, 5000);
        });

        // Change the update timer for when the update frequency changes
        this.manager.on("new-frequency", async freq => {
            // Subtract 5 minutes just to be safe that we restart it before the timeout period
            this.opts.refreshTimerMs = freq - 1000 * 60 * 5;
        });

        this.url = await this.manager.start();
        return this.url;
    }

    /**
     * Disconnect from LocalTunnel
     */
    async disconnect(): Promise<void> {
        try {
            if (this.manager) {
                this.manager.removeAllListeners();
                this.manager.stop();
            }
        } finally {
            this.url = null;
        }
    }
}
