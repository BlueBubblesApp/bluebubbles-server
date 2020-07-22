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
    async restart(): Promise<string> {
        try {
            await this.stop();
            await this.start();
        } catch (ex) {
            Server().log(`Failed to restart ngrok! ${ex.message}`, "error");
        }

        return this.url;
    }
}
