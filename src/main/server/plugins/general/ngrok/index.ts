import * as ngrok from "ngrok";

import { IPluginConfig, IPluginConfigPropItemType, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { GeneralPluginBase } from "../base";

const configuration: IPluginConfig = {
    name: "ngrok",
    type: IPluginTypes.GENERAL,
    displayName: "ngrok",
    description: "ngrok allows your Mac to be accessible to the internet, over a specific port.",
    version: 1,
    properties: [
        {
            name: "port",
            label: "Access Port",
            type: IPluginConfigPropItemType.NUMBER,
            description: "Enter the local port to open up to outside access.",
            default: 1234,
            placeholder: "Enter a number between 100 and 65,535. This should match any running socket servers.",
            required: true
        },
        {
            name: "region",
            label: "Server Region",
            type: IPluginConfigPropItemType.STRING,
            description: "Select the ngrok server region you want to use. Pick one closest to where you live!",
            options: [
                {
                    label: "US",
                    value: "us",
                    default: true
                },
                {
                    label: "EU",
                    value: "eu",
                    default: false
                },
                {
                    label: "AU",
                    value: "au",
                    default: false
                },
                {
                    label: "AP",
                    value: "ap",
                    default: false
                },
                {
                    label: "SA",
                    value: "sa",
                    default: false
                },
                {
                    label: "JP",
                    value: "jp",
                    default: false
                },
                {
                    label: "IN",
                    value: "in",
                    default: false
                }
            ],
            required: false
        },
        {
            name: "token",
            label: "Auth Token (Optional)",
            type: IPluginConfigPropItemType.STRING,
            description: "If you have an ngrok auth token, you can enter it here for longer session limits",
            default: "",
            required: false
        }
    ],
    dependencies: [] // Other plugins this depends on (<type>.<name>)
};

// const sevenHours = 1000 * 60 * 60 * 7;  // This is the old ngrok timeout
const oneHour45 = 1000 * 60 * (60 + 45); // This is the new ngrok timeout

export default class NgrokPlugin extends GeneralPluginBase {
    refreshTimer: NodeJS.Timeout = null;

    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    /**
     * Helper for checking if we are connected
     */
    // eslint-disable-next-line class-methods-use-this
    isConnected(): boolean {
        const url = ngrok.getUrl();
        return url && url.length > 0;
    }

    async startup() {
        // If there is a ngrok API key set, and we have a refresh timer going, kill it
        const ngrokKey = this.getProperty("token");
        if (ngrokKey && this.refreshTimer) clearTimeout(this.refreshTimer);

        // As long as the auth token isn't null or undefined, set it
        let authtoken = null;
        if (ngrokKey !== null && ngrokKey !== undefined) {
            authtoken = ngrokKey;
        }

        const port = this.getProperty("port") as number;
        if (port < 0 || port > 65535) {
            this.logger.error(`Invalid port provided! Port provided: ${port}`);
            return;
        }

        // Connect to ngrok
        await ngrok.connect({
            port,
            authtoken,
            // This is required to run ngrok in production
            binPath: (bPath: string) => bPath.replace("app.asar", "app.asar.unpacked"),
            onStatusChange: async (status: string) => {
                this.logger.info(`Ngrok status: ${status}`);

                // If the status is closed, restart the server
                if (status === "closed") await this.restart();
            },
            onLogEvent: (log: string) => {
                this.logger.debug(log);

                // Sanitize the log a bit (remove quotes and standardize)
                const cmp_log = log.replace(/"/g, "").replace(/eror/g, "error");

                // Check for any errors or other restart cases
                if (cmp_log.includes("lvl=error") || cmp_log.includes("lvl=crit")) {
                    this.logger.info(`Ngrok status: Error Detected -> Restarting...`);
                } else if (log.includes("remote gone away")) {
                    this.logger.info(`Ngrok status: "Remote gone away" -> Restarting...`);
                    this.restart();
                } else if (log.includes("command failed")) {
                    this.logger.info(`Ngrok status: "Command failed" -> Restarting...`);
                    this.restart();
                }
            }
        });

        // If there is no API key present, set a timer to auto-refresh after 7 hours.
        // 8 hours is the "max" time
        if (!ngrokKey) {
            if (this.refreshTimer) clearTimeout(this.refreshTimer);

            this.logger.debug("Starting Ngrok refresh timer. Waiting 1 hour and 45 minutes");
            this.refreshTimer = setTimeout(async () => {
                this.logger.debug("Restarting Ngrok process due to session timeout...");
                await this.restart();
            }, oneHour45);
        }

        this.emit("ngrok-url-change", ngrok.getUrl());
    }

    /**
     * Helper for restarting the ngrok connection
     */
    async restart(): Promise<boolean> {
        const maxTries = 3;
        let tries = 0;
        let connected = false;

        // Retry when we aren't connected and we haven't hit our try limit
        while (tries < maxTries && !connected) {
            tries += 1;

            // Set the wait time based on which try we are attempting
            const wait = tries > 1 ? 2000 * tries : 1000;
            this.logger.info(`Attempting to restart ngrok (attempt ${tries}; ${wait} ms delay)`);
            connected = await this.restartHandler(wait);
        }

        // Log some nice things (hopefully)
        if (connected) {
            this.logger.info(`Successfully connected to ngrok after ${tries} ${tries === 1 ? "try" : "tries"}`);
        } else {
            this.logger.info(`Failed to connect to ngrok after ${maxTries} tries`);
        }

        if (tries >= maxTries) {
            this.logger.info("Reached maximum retry attempts for Ngrok. Force restarting app...");
            this.emit("max-retries"); // Not sure what to do yet here
        }

        return connected;
    }

    /**
     * Restarts ngrok (retries 3 times)
     */
    async restartHandler(wait = 1000): Promise<boolean> {
        try {
            await this.shutdown();
            await new Promise((resolve, _) => setTimeout(resolve, wait));
            await this.startup();
        } catch (ex) {
            this.logger.error(`Failed to restart ngrok!\n${ex}`);

            const errString = ex?.toString() ?? "";
            if (errString.includes("socket hang up") || errString.includes("[object Object]")) {
                this.logger.info("Socket hang up detected. Performing full server restart...");
                this.emit("max-retries"); // Not sure what to do yet here
            }

            return false;
        }

        return true;
    }

    async shutdown() {
        try {
            await ngrok.disconnect();
            await ngrok.kill();
        } finally {
            this.refreshTimer = null;
        }
    }
}
