import { CloudflareManager } from "@server/managers/cloudflareManager";
import { Proxy } from "../proxy";

export class CloudflareService extends Proxy {
    manager: CloudflareManager;

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

    /**
     * Sets up a connection to the LocalTunnel servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connect(): Promise<string> {
        // Create the connection
        this.manager = new CloudflareManager();

        // When we get a new URL, set the URL and update
        this.manager.on("new-url", async url => {
            this.url = url;

            // 5 second delay to allow DNS records to update
            setTimeout(() => {
                this.applyAddress(this.url);
            }, 5000);
        });

        // When we get a new URL, set the URL and update
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
