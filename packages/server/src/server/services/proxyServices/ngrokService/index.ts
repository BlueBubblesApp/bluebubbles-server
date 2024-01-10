import { isEmpty, safeTrim } from "@server/helpers/utils";
import path from "path";
import fs from "fs";
import { Server } from "@server";
import { connect, disconnect, kill, authtoken, Ngrok, upgradeConfig } from "ngrok";
import { Proxy } from "../proxy";
import { app } from "electron";
import { userHomeDir } from "@server/fileSystem";

// const sevenHours = 1000 * 60 * 60 * 7;  // This is the old ngrok timeout
const oneHour45 = 1000 * 60 * (60 + 45); // This is the new ngrok timeout

export class NgrokService extends Proxy {
    constructor() {
        super({
            name: "Ngrok",
            refreshTimerMs: oneHour45,
            autoRefresh: true
        });
    }

    /**
     * Sets up a connection to the Ngrok servers, opening a secure
     * tunnel between the internet and your Mac (iMessage server)
     */
    async connect(): Promise<string> {
        // If there is a ngrok API key set, and we have a refresh timer going, kill it
        const ngrokKey = Server().repo.getConfig("ngrok_key") as string;
        let ngrokProtocol = (Server().repo.getConfig("ngrok_protocol") as Ngrok.Protocol) ?? "http";

        if (isEmpty(ngrokKey)) {
            throw new Error('You must provide an Auth Token to use the Ngrok Proxy Service!');
        }

        await this.migrateConfigFile();

        const opts: Ngrok.Options = {
            port: Server().repo.getConfig("socket_port") ?? 1234,
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
                    if (
                        cmp_log.includes(
                            "The authtoken you specified does not look like a proper ngrok tunnel authtoken"
                        ) ||
                        cmp_log.includes("The authtoken you specified is properly formed, but it is invalid")
                    ) {
                        Server().log(`Ngrok Auth Token is invalid, removing...!`, "error");
                        Server().repo.setConfig("ngrok_key", "");
                    } else if (cmp_log.includes("TCP tunnels are only available after you sign up")) {
                        Server().log(`In order to use Ngrok with TCP, you must enter an Auth Token!`, "error");
                    } else {
                        Server().log(`Ngrok status: Error Detected!`);
                    }
                } else if (log.includes("remote gone away")) {
                    Server().log(`Ngrok status: "Remote gone away" -> Restarting...`);
                    this.restart();
                } else if (log.includes("command failed")) {
                    Server().log(`Ngrok status: "Command failed" -> Restarting...`);
                    this.restart();
                }
            }
        };

        // Apply the Ngrok auth token
        opts.authtoken = safeTrim(ngrokKey);
        await authtoken({
            authtoken: safeTrim(ngrokKey),
            binPath: (bPath: string) => bPath.replace("app.asar", "app.asar.unpacked")
        });

        // If there is no key, force http
        if (isEmpty(ngrokKey)) {
            ngrokProtocol = "http";
        }

        // Set the protocol
        opts.proto = ngrokProtocol;

        // Connect to ngrok
        return connect(opts);
    }

    async migrateConfigFile(): Promise<void> {
        const newConfig = path.join(app.getPath("userData"), 'ngrok', 'ngrok.yml');
        const oldConfig = path.join(userHomeDir(), '.ngrok2', '/ngrok.yml');

        // If the new config file already exists, don't do anything
        if (fs.existsSync(newConfig)) return;

        // If the old config file doesn't exist, don't do anything
        if (!fs.existsSync(oldConfig)) return;

        // If the old config file exists and is empty, we can delete it
        // so that it's recreated in the proper location
        const contents = fs.readFileSync(oldConfig).toString('utf-8');
        if (!contents || isEmpty(contents.trim())) {
            Server().log('Detected old & empty Ngrok config file. Removing file...', 'debug');
            fs.unlinkSync(oldConfig);
            return;
        }

        // Upgrade the old config if the new config doesn't exist
        // and the old config is not empty.
        try {
            Server().log('Ngrok config file needs upgrading. Upgrading...', 'debug');
            await upgradeConfig({
                relocate: true,
                binPath: (bPath: string) => bPath.replace("app.asar", "app.asar.unpacked")
            });
        } catch (ex) {
            Server().log('An error occurred while upgrading the Ngrok config file!', 'debug');
        }
    }

    /**
     * Disconnect from ngrok
     */
    async disconnect(): Promise<void> {
        try {
            await disconnect();
            await kill();
        } catch (ex: any) {
            Server().log("Failed to disconnect from Ngrok!", "debug");
        } finally {
            this.url = null;
        }
    }
}
