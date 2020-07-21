import { Server } from "@server/index";
import * as ngrok from "ngrok";

export class NgrokService {
    url: string;

    constructor() {
        this.url = null;
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
        this.url = await ngrok.connect({
            port: Server().repo.getConfig("socket_port"),
            // This is required to run ngrok in production
            binPath: bPath => bPath.replace("app.asar", "app.asar.unpacked"),
            onStatusChange: async (status: string) => {
                Server().log(`Ngrok status: ${status}`);

                // If the status is closed, restart the server
                if (status === "closed") await this.restart();
            },
            onLogEvent: (log: string) => {
                Server().log(log);
            }
        });

        await Server().repo.setConfig("server_address", this.url);
    }

    /**
     * Disconnect from ngrok
     */
    async stop(): Promise<void> {
        try {
            await ngrok.disconnect();
        } finally {
            this.url = null;
        }
    }

    /**
     * Helper for restarting the ngrok connection
     */
    async restart(): Promise<string> {
        await this.stop();
        await this.start();
        return this.url;
    }
}
