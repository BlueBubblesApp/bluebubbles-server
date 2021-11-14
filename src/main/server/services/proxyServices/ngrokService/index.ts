import { isEmpty, safeTrim } from "@server/helpers/utils";
import { Server } from "@server/index";
import { connect, disconnect, kill, authtoken, Ngrok } from "ngrok";
import { Proxy } from "../proxy";

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

        const opts: Ngrok.Options = {
            port: Server().repo.getConfig("socket_port") ?? 1234,
            region: (Server().repo.getConfig("ngrok_region") as Ngrok.Region) ?? "us",
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

        // If we have a key, use it
        if (ngrokKey !== null && ngrokKey !== undefined) {
            opts.authtoken = safeTrim(ngrokKey);
            await authtoken({
                authtoken: safeTrim(ngrokKey),
                binPath: (bPath: string) => bPath.replace("app.asar", "app.asar.unpacked")
            });
        }

        // If there is no key, force http
        if (isEmpty(ngrokKey)) {
            ngrokProtocol = "http";
        }

        // Set the protocol
        opts.proto = ngrokProtocol;

        // Connect to ngrok
        return connect(opts);
    }

    /**
     * Disconnect from ngrok
     */
    async disconnect(): Promise<void> {
        try {
            await disconnect();
            await kill();
        } catch (ex: any) {
            Server().log("Failed to disconnect from Ngrok!", "warn");
        } finally {
            this.url = null;
        }
    }
}
