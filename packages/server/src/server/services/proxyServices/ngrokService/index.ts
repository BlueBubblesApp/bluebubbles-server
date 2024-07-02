import { isEmpty, safeTrim } from "@server/helpers/utils";
import path from "path";
import fs from "fs";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { connect, disconnect, kill, authtoken, Ngrok, upgradeConfig } from "ngrok";
import { Proxy } from "../proxy";
import { app } from "electron";
import { userHomeDir } from "@server/fileSystem";

// const sevenHours = 1000 * 60 * 60 * 7;  // This is the old ngrok timeout
const oneHour45 = 1000 * 60 * (60 + 45); // This is the new ngrok timeout

export class NgrokService extends Proxy {
    tag = "NgrokService";

    static get daemonDir() {
        return path.join(FileSystem.resources, "macos", "daemons", "ngrok", (process.arch === "arm64") ? "arm64" : "x86");
    }

    constructor() {
        super({
            name: "Ngrok",
            refreshTimerMs: oneHour45,
            autoRefresh: true
        });
    }

    async checkForError(log: string, err: any = null) {
        let handled = true;
        // Check for any errors or other restart cases
        if (log.includes("lvl=error") || log.includes("lvl=crit")) {
            if (
                log.includes(
                    "The authtoken you specified does not look like a proper ngrok tunnel authtoken"
                ) ||
                log.includes("The authtoken you specified is properly formed, but it is invalid")
            ) {
                this.log.error(`Ngrok Auth Token is invalid, removing...!`);
                await Server().repo.setConfig("ngrok_key", "");
            } else if (log.includes("TCP tunnels are only available after you sign up")) {
                this.log.error(`In order to use Ngrok with TCP, you must enter an Auth Token!`);
            } else {
                this.log.info(`Ngrok status: Error Detected!`);
            }
        } else if (log.includes("remote gone away")) {
            this.log.info(`Ngrok status: "Remote gone away" -> Restarting...`);
            this.restart();
        } else if (log.includes("command failed")) {
            this.log.info(`Ngrok status: "Command failed" -> Restarting...`);
            this.restart();
        } else if (log.includes("ERR_NGROK_313")) {
            await Server().repo.setConfig("ngrok_custom_domain", "");
            this.log.error(
                "Failed to use custom Ngrok subdomain. " +
                "You must reserve a subdomain on the Ngrok website! " +
                "Removing custom subdomain...");
        } else if (log.includes("socket hang up") || log.includes("[object Object]")) {
            this.log.info(
                `Failed to restart ${this.opts.name}! Socket hang up detected. Performing full server restart...`);
            Server().relaunch();
        } else if (err?.body?.details?.err) {
            this.log.error(`Failed to restart ${this.opts.name}! Error: ${err?.body?.details?.err}`);
        } else {
            handled = false;
        }

        return handled;
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
            throw new Error("You must provide an Auth Token to use the Ngrok Proxy Service!");
        }

        await this.migrateConfigFile();

        const ngrokDomain = (Server().repo.getConfig("ngrok_custom_domain") as string).trim();
        const opts: Ngrok.Options = {
            port: Server().repo.getConfig("socket_port") ?? 1234,
            hostname: isEmpty(ngrokDomain) ? null : ngrokDomain,
            // Override the bin path with our own
            binPath: (_: string) => NgrokService.daemonDir,
            onStatusChange: async (status: string) => {
                this.log.info(`Ngrok status: ${status}`);

                // If the status is closed, restart the server
                if (status === "closed") await this.restart();
            },
            onLogEvent: (log: string) => {
                this.log.debug(log);

                // Sanitize the log a bit (remove quotes and standardize)
                const saniLog = log.replace(/"/g, "").replace(/eror/g, "error");
                this.checkForError(saniLog);
            }
        };

        // Apply the Ngrok auth token
        opts.authtoken = safeTrim(ngrokKey);
        await authtoken({
            authtoken: safeTrim(ngrokKey),
            binPath: (_: string) => NgrokService.daemonDir
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
        const newConfig = path.join(app.getPath("userData"), "ngrok", "ngrok.yml");
        const oldConfig = path.join(userHomeDir(), ".ngrok2", "/ngrok.yml");

        // If the new config file already exists, don't do anything
        if (fs.existsSync(newConfig)) return;

        // If the old config file doesn't exist, don't do anything
        if (!fs.existsSync(oldConfig)) return;

        // If the old config file exists and is empty, we can delete it
        // so that it's recreated in the proper location
        const contents = fs.readFileSync(oldConfig).toString("utf-8");
        if (!contents || isEmpty(contents.trim())) {
            this.log.debug("Detected old & empty Ngrok config file. Removing file...");
            fs.unlinkSync(oldConfig);
            return;
        }

        // Upgrade the old config if the new config doesn't exist
        // and the old config is not empty.
        try {
            this.log.debug("Ngrok config file needs upgrading. Upgrading...");
            await upgradeConfig({
                relocate: true,
                binPath: (_: string) => NgrokService.daemonDir
            });
        } catch (ex) {
            this.log.debug("An error occurred while upgrading the Ngrok config file!");
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
            this.log.debug("Failed to disconnect from Ngrok!");
        } finally {
            this.url = null;
        }
    }
}
