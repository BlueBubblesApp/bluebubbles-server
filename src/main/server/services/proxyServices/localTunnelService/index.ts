import { Server } from "@server/index";
import * as LocalTunnel from "localtunnel";
import { Proxy } from "../proxy";

const threeHours = 1000 * 60 * 60 * 3;

export class LocalTunnelService extends Proxy {
    tunnel: any;

    constructor() {
        super({
            name: "LocalTunnel",
            refreshTimerMs: threeHours,
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
        this.tunnel = await LocalTunnel({
            port: Server().repo.getConfig("socket_port") as number,
            allow_invalid_cert: true
        });

        this.tunnel.on("close", async () => {
            Server().log("LocalTunnel has been closed! Restarting...");
            await this.restart();
        });

        this.tunnel.on("error", async (err: any) => {
            Server().log("LocalTunnel has run into an error! Restarting...");
            Server().log(err, "error");
            await this.restart();
        });

        return this.tunnel.url;
    }

    /**
     * Disconnect from LocalTunnel
     */
    async disconnect(): Promise<void> {
        try {
            if (this.tunnel) {
                this.tunnel.removeAllListeners();
                this.tunnel.close();
            }
        } finally {
            this.url = null;
        }
    }
}
