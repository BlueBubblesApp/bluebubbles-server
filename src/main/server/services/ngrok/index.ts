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
            binPath: bPath => bPath.replace("app.asar", "app.asar.unpacked")
        });

        await Server().repo.setConfig("server_address", this.url);
    }

    /**
     * Disconnect from ngrok
     */
    async stop(): Promise<void> {
        if (!this.isConnected()) return;
        await ngrok.disconnect();
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
