import { ServerSingleton } from "@server/index";
import * as ngrok from "ngrok";

export class NgrokService {
    ngrokUrl: string;

    constructor() {
        this.ngrokUrl = null;
    }

    /**
     * Helper for checking if we are connected
     */
    isConnected(): boolean {
        return this.ngrokUrl !== null;
    }

    /**
     * Sets up a connection to the Ngrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async start(): Promise<void> {
        this.ngrokUrl = await ngrok.connect({
            port: ServerSingleton().repo.getConfig("socket_port"),
            // This is required to run ngrok in production
            binPath: bPath => bPath.replace("app.asar", "app.asar.unpacked")
        });

        await ServerSingleton().repo.setConfig("server_address", this.ngrokUrl);

        // Emit this over the socket
        if (ServerSingleton().socket) ServerSingleton().socket.server.emit("new-server", this.ngrokUrl);

        if (ServerSingleton().socket) await ServerSingleton().sendNotification("new-server", this.ngrokUrl);
        await ServerSingleton().fcm.setServerUrl(this.ngrokUrl);
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
        return this.ngrokUrl;
    }
}
