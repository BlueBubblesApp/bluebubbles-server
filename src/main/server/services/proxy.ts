import { Server } from "@server/index";

type ProxyOptions = {
    name: string;
    autoRefresh?: boolean;
    refreshTimerMs?: number;
};

const sevenHours = 1000 * 60 * 60 * 7;

abstract class Proxy {
    opts: ProxyOptions;

    url: string;

    refreshTimer: NodeJS.Timeout = null;

    constructor(opts: ProxyOptions) {
        this.opts = opts;
        this.url = null;
        this.refreshTimer = null;

        this.opts.refreshTimerMs = this.opts.refreshTimerMs ?? sevenHours;
        this.opts.autoRefresh = this.opts.autoRefresh ?? false;
    }

    /**
     * Helper for checking if we are connected
     */
    isConnected(): boolean {
        return this.url !== null;
    }

    /**
     * Checks to see if the service can be started
     */
    canStart(): boolean {
        const enabledProxy = Server().repo.getConfig("proxy_service") as string;
        return enabledProxy.toLowerCase() === this.opts.name.toLowerCase();
    }

    /**
     * Sets up a connection to the Ngrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async start(): Promise<void> {
        if (!this.canStart()) {
            Server().log(`${this.opts.name} proxy is diabled. Not restarting.`);
            return;
        }

        // Clear the refresh timer
        if ((this.opts.autoRefresh ?? false) && this.refreshTimer) clearTimeout(this.refreshTimer);

        // Connect to the service
        try {
            this.url = await this.connect();
            if (this.url) {
                await Server().repo.setConfig("server_address", this.url);
            }
        } catch (ex: any) {
            Server().log(`Failed to connect to ${this.opts.name}! Error: ${ex.toString()}`);
            throw ex;
        }

        // Start the new refresh timer (if available)
        if (this.opts.autoRefresh ?? false) {
            Server().log(`Starting ${this.opts.name} refresh timer. Waiting ${this.opts.refreshTimerMs} ms`, "debug");
            this.refreshTimer = setTimeout(async () => {
                Server().log(`Restarting ${this.opts.name} process due to session timeout...`, "debug");
                await this.restart();
            }, this.opts.refreshTimerMs);
        }
    }

    /**
     * Connect to the proxy, return the URL
     */
    abstract connect(): Promise<string>;

    /**
     * Disconnect from proxy
     */
    abstract disconnect(): Promise<void>;

    /**
     * Helper for restarting the ngrok connection
     */
    async restart(): Promise<boolean> {
        if (!this.canStart()) {
            Server().log(`${this.opts.name} proxy is diabled. Not restarting.`);
            return false;
        }

        const maxTries = 10;
        let tries = 0;
        let connected = false;

        // Retry when we aren't connected and we haven't hit our try limit
        while (tries < maxTries && !connected) {
            tries += 1;

            // Set the wait time based on which try we are attempting
            const wait = tries > 1 ? 2000 * tries : 1000;
            Server().log(`Attempting to restart ${this.opts.name} (attempt ${tries}; ${wait} ms delay)`);
            connected = await this.restartHandler(wait);
        }

        // Log some nice things (hopefully)
        if (connected) {
            Server().log(`Successfully connected to ${this.opts.name} after ${tries} ${tries === 1 ? "try" : "tries"}`);
        } else {
            Server().log(`Failed to connect to ${this.opts.name} after ${maxTries} tries`);
        }

        if (tries >= maxTries) {
            Server().log(`Reached maximum retry attempts for ${this.opts.name}. Force restarting app...`);
            Server().relaunch();
        }

        return connected;
    }

    /**
     * Restarts ngrok (retries 3 times)
     */
    async restartHandler(wait = 1000): Promise<boolean> {
        try {
            await this.disconnect();
            await new Promise((resolve, _) => setTimeout(resolve, wait));
            await this.start();
        } catch (ex: any) {
            Server().log(`Failed to restart ${this.opts.name}!\n${ex}`, "error");

            const errString = ex?.toString() ?? "";
            if (errString.includes("socket hang up") || errString.includes("[object Object]")) {
                Server().log("Socket hang up detected. Performing full server restart...");
                Server().relaunch();
            }

            return false;
        }

        return true;
    }
}

export { Proxy, ProxyOptions };
