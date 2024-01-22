import * as net from "net";
import { Server } from "@server";
import { LogLevel } from "electron-log";
import { LineExtractor } from "./lineExtractor";
import { app } from "electron";
import { handleLine } from "./commands";


const PROMPT = 'bluebubbles-configurator>';


export class RemoteConfigService {
    server: net.Server;

    clients: Set<net.Socket> = new Set();

    socketPath: string;

    constructor () {
        // not sure if this socketPath stuff belongs in fileSystem/index.ts
        const isDev = process.env.NODE_ENV !== "production";
        this.socketPath = app.getPath("userData");
        if (isDev) {
            this.socketPath = path.join(this.socketPath, "bluebubbles-server");
        }
        this.socketPath = path.join(this.socketPath, "remote-config.sock");

        this.log(`Remote Config Service socket path: ${this.socketPath}`, "debug");
    }

    private log(message: string, level: LogLevel = "info") {
        Server().log(`[RemoteConfigService] ${String(message)}`, level);
    }

    start() {
        this.server = net.createServer({allowHalfOpen: false}, (client: net.Socket) => {
            this.handleClient(client);
        });

        if (fs.existsSync(this.socketPath)) {
            fs.unlinkSync(this.socketPath);
        }
        this.server.listen(this.socketPath);

        this.server.on("error", err => {
            this.log("An error occured in the RemoteConfigService server socket", "error");
            this.log(err.toString(), "error");
            this.closeServer();
        });
    }

    private handleClient(client: net.Socket) {
        this.log("Remote Config Service client connected", "debug");

        this.clients.add(client);
        const lineExtractor = new LineExtractor();

        client.write(`Welcome to the BlueBubbles configurator!\nType 'help' for help.\nType 'exit' to exit.\n${PROMPT} `);

        client.on("data", async (data: Buffer) => {
            for (const line of lineExtractor.feed(data)) {
                await this.handleLine(client, line);
            }
        });
        client.on("close", () => {
            this.log("Remote Config Service client closed", "debug");
            this.clients.delete(client);
        });
        client.on("error", err => {
            this.log("An error occured in a RemoteConfigService client", "error");
            this.log(err.toString(), "error");
        });
    }

    private async handleLine (client: net.Socket, line: string) {
        this.log(`Remote Config Service client received line: ${JSON.stringify(line)}`, "debug");
        const [response, keepOpen] = await handleLine(line);
        if (response) {
            client.write(`${response}\n`);
        }
        if (keepOpen) {
            client.write(`${PROMPT} `);
        }
        else {
            client.destroy();
        }
    }

    private closeServer () {
        if (this.server === null) {
            return;
        }
        this.server.close();
        this.server = null;
    }

    private destroyAllClients () {
        for (const client of this.clients) {
            client.destroy();
        }
        this.clients = new Set();
    }

    stop() {
        this.log("Stopping Remote Config Service...");

        this.destroyAllClients();
        this.closeServer();
    }
}
