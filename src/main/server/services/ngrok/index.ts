import { app } from "electron";
import { Server } from "@server/index";
import { connect, disconnect, kill, authtoken } from "ngrok";

const sevenHours = 1000 * 60 * 60 * 7;

export class NgrokService {
    url: string;

    refreshTimer: NodeJS.Timeout = null;

    constructor() {
        this.url = null;
        this.refreshTimer = null;
    }

    /**
     * Helper for checking if we are connected
     */
    isConnected(): boolean {
        return this.url !== null;
    }

    /**
     * Sets up a connection to the Ngrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async start(): Promise<void> {
        const enableNgrok = Server().repo.getConfig("enable_ngrok") as boolean;
        if (!enableNgrok) {
            Server().log("Ngrok is diabled. Skipping.");
            return;
        }

        // If there is a ngrok API key set, and we have a refresh timer going, kill it
        const ngrokKey = Server().repo.getConfig("ngrok_key") as string;
        if (ngrokKey && this.refreshTimer) clearTimeout(this.refreshTimer);

        // As long as the auth token isn't null or undefined, set it
        if (ngrokKey !== null && ngrokKey !== undefined)
            await authtoken({
                authtoken: ngrokKey,
                binPath: (bPath: string) => bPath.replace("app.asar", "app.asar.unpacked")
            });

        // Connect to ngrok
        this.url = await connect({
            port: Server().repo.getConfig("socket_port"),
            // This is required to run ngrok in production
            binPath: (bPath: string) => bPath.replace("app.asar", "app.asar.unpacked"),
            onStatusChange: async (status: string) => {
                Server().log(`Ngrok status: ${status}`);

                // If the status is closed, restart the server
                if (status === "closed") await this.restart();
            },
            onLogEvent: (log: string) => {
                Server().log(log, "debug");

                // Sanitize the log a bit (remove quotes and standardize)
                const cmp_log = log.replace(/"/g, "").replace(/eror/g, "error");

                // Check for any errors or other restart cases
                if (cmp_log.includes("lvl=error") || cmp_log.includes("lvl=crit")) {
                    Server().log(`Ngrok status: Error Detected -> Restarting...`);
                } else if (log.includes("remote gone away")) {
                    Server().log(`Ngrok status: "Remote gone away" -> Restarting...`);
                    this.restart();
                } else if (log.includes("command failed")) {
                    Server().log(`Ngrok status: "Command failed" -> Restarting...`);
                    this.restart();
                }
            }
        });

        // If there is no API key present, set a timer to auto-refresh after 7 hours.
        // 8 hours is the "max" time
        if (!ngrokKey) {
            if (this.refreshTimer) clearTimeout(this.refreshTimer);

            Server().log("Starting Ngrok refresh timer. Waiting 7 hours...", "debug");
            this.refreshTimer = setTimeout(async () => {
                Server().log("Restarting Ngrok process due to session timeout...", "debug");
                await this.restart();
            }, sevenHours);
        }

        // Set the server address. This will emit to all listeners.
        await Server().repo.setConfig("server_address", this.url);
    }

    /**
     * Disconnect from ngrok
     */
    async stop(): Promise<void> {
        try {
            await disconnect();
            await kill();
        } finally {
            this.url = null;
        }
    }

    /**
     * Helper for restarting the ngrok connection
     */
    async restart(): Promise<boolean> {
        const enableNgrok = Server().repo.getConfig("enable_ngrok") as boolean;
        if (!enableNgrok) {
            Server().log("Ngrok is diabled. Skipping.");
            return false;
        }

        const maxTries = 3;
        let tries = 0;
        let connected = false;

        // Retry when we aren't connected and we haven't hit our try limit
        while (tries < maxTries && !connected) {
            tries += 1;

            // Set the wait time based on which try we are attempting
            const wait = tries > 1 ? 2000 * tries : 1000;
            Server().log(`Attempting to restart ngrok (attempt ${tries}; ${wait} ms delay)`);
            connected = await this.restartHandler(wait);
        }

        // Log some nice things (hopefully)
        if (connected) {
            Server().log(`Successfully connected to ngrok after ${tries} ${tries === 1 ? "try" : "tries"}`);
        } else {
            Server().log(`Failed to connect to ngrok after ${maxTries} tries`);
        }

        if (tries >= maxTries) {
            Server().log("Reached maximum retry attempts for Ngrok. Force restarting app...");
            Server().relaunch();
        }

        return connected;
    }

    /**
     * Restarts ngrok (retries 3 times)
     */
    async restartHandler(wait = 1000): Promise<boolean> {
        try {
            await this.stop();
            await new Promise((resolve, _) => setTimeout(resolve, wait));
            await this.start();
        } catch (ex) {
            Server().log(`Failed to restart ngrok!\n${ex}`, "error");

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
