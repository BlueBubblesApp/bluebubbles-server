import { Proxy } from "../proxy";
import { ZrokManager } from "@server/managers/zrokManager";
import { Server } from "@server";
import { isEmpty, waitMs } from "@server/helpers/utils";

export class ZrokService extends Proxy {
    tag = "ZrokService";

    manager: ZrokManager;

    connectPromise: Promise<string>;

    constructor() {
        super({
            name: "Zrok",
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
     * Sets up a connection to the Zrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connect(): Promise<string> {
        if (this.connectPromise) {
            this.log.debug("Already connecting to Zrok. Waiting for connection to complete.");
            await this.connectPromise;
        }

        const token = Server().repo.getConfig("zrok_token") as string;
        if (isEmpty(token)) {
            throw new Error("Auth Token missing! Please perform the Zrok setup in the settings page.");
        }

        try {
            this.connectPromise = this._connect();
            this.url = await this.connectPromise;
            this.connectPromise = null;
            return this.url;
        } catch (ex: any) {
            this.connectPromise = null;
            this.log.info(`Failed to connect to Zrok! Error: ${ex.toString()}`);
            throw ex;
        }
    }

    async _connect(): Promise<string> {
        // Create the connection
        if (!this.manager) {
            this.manager = new ZrokManager();
        }

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
                await waitMs(5000);
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
     * Disconnect from Zrok
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
