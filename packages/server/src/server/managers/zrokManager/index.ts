import { isNotEmpty, isEmpty } from "@server/helpers/utils";
import { Loggable, getLogger } from "@server/lib/logging/Loggable";
import { FileSystem } from "@server/fileSystem";
import * as zx from "zx";
import axios from "axios";
import { app } from "electron";
import { Server } from "@server";
import { ProcessOutput } from "zx";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import path from "path";

export class ZrokManager extends Loggable {
    tag = "ZrokManager";

    static get daemonPath() {
        return path.join(FileSystem.resources, "macos", "daemons", "zrok", "zrok");
    }

    proc: ChildProcessWithoutNullStreams;

    currentProxyUrl: string;

    isRestarting = false;

    static proxyUrlRegex = /\b(https:\/\/.*?\.zrok.io)\b/m;

    async start(): Promise<string> {
        try {
            this.emit("started");
            return this.connectHandler();
        } catch (ex) {
            this.log.error(`Failed to run Zrok daemon! ${ex.toString()}`);
            this.emit("error", ex);
        }

        return null;
    }

    private async connectHandler(): Promise<string> {
        const port = Server().repo.getConfig("socket_port") as string;
        const reservedTunnel = (Server().repo.getConfig("zrok_reserve_tunnel") as boolean) ?? false;
        const reservedToken = Server().repo.getConfig("zrok_reserved_token") as string;
        const reservedName = Server().repo.getConfig("zrok_reserved_name") as string;

        // The token will equal the name if it's already reserved
        let reservedNameToken = reservedName;
        if (reservedTunnel && (isEmpty(reservedToken) || reservedToken !== reservedName)) {
            reservedNameToken = await ZrokManager.reserve(reservedName);
            // If the token is not empty, but the tunnel is not reserved, release it
        } else if (!reservedTunnel && isNotEmpty(reservedToken)) {
            try {
                await ZrokManager.release(reservedToken);
            } catch (ex) {
                this.log.debug(`Failed to release reserved Zrok tunnel! Error: ${ex}`);
            }
        }

        return new Promise((resolve, reject) => {
            // Didn't use zx here because I couldn't figure out how to pipe the stdout
            // properly, without taking over the terminal outputs.
            // Conditionally change the command based on if we are reserving a tunnel or not
            const commndFlags = [
                "share",
                ...(reservedTunnel ? ["reserved", "--headless"] : ["public", "--backend-mode", "proxy", "--headless"]),
                ...(reservedTunnel ? [reservedNameToken] : [`0.0.0.0:${port}`])
            ];

            this.proc = spawn(ZrokManager.daemonPath, commndFlags);
            this.proc.stdout.on("data", chunk => this.handleData(chunk));
            this.proc.stderr.on("data", chunk => this.handleData(chunk));

            this.on("new-url", url => resolve(url));
            this.on("error", err => reject(err));

            setTimeout(() => {
                reject(new Error("Failed to connect to Zrok after 2 minutes..."));
            }, 1000 * 60 * 2); // 2 minutes
        });
    }

    async stop() {
        if (!this.proc) return;
        this.currentProxyUrl = null;
        await this.proc.kill();
    }

    setProxyUrl(url: string) {
        if (isEmpty(url) || !url.startsWith("https://") || url === this.currentProxyUrl) return;
        this.log.info(`Setting Zrok Proxy URL: ${url}`);
        this.currentProxyUrl = url;
        this.emit("new-url", this.currentProxyUrl);
    }

    async handleData(chunk: any) {
        const data: string = chunk.toString();
        if (data.includes("dial tcp: lookup api.zrok.io")) {
            this.handleError("Failed to connect to Zrok's servers! Please make sure you're connected to the internet.");
            return;
        } else if (data.includes("getShareDetailNotFound")) {
            this.handleError("Failed to get Zrok share details! Reserved share not found!");
            return;
        } else if (data.includes("[ERROR]")) {
            this.handleError(data.substring(data.indexOf("[ERROR]")));
            return;
        }

        this.detectNewUrl(data);
    }

    private detectNewUrl(data: string) {
        const urlMatches = data.match(ZrokManager.proxyUrlRegex);
        if (isNotEmpty(urlMatches)) this.setProxyUrl(urlMatches[1]);
    }

    handleError(chunk: any) {
        this.emit("error", chunk);
    }

    static async getInvite(email: string): Promise<void> {
        try {
            // Use axios to get the invite with the following spec
            await axios.post("https://api.zrok.io/api/v1/invite", JSON.stringify({ email }), {
                headers: {
                    "Content-Type": "application/zrok.v1+json",
                    Accept: "application/zrok.v1+json",
                    "User-Agent": `BlueBubbles Server/${app.getVersion()}`,
                    "Accept-Encoding": "gzip",
                    Host: "api.zrok.io"
                }
            });
        } catch (ex: any) {
            const data = ex?.response?.data;
            if (isEmpty(data)) {
                throw new Error(`Failed to dispatch Zrok invite! Please check your email address and try again.`);
            } else if (data.includes("duplicate")) {
                throw new Error("This email is already registered with Zrok!");
            }

            throw new Error(data);
        }
    }

    static async setToken(token: string): Promise<ProcessOutput> {
        try {
            return await zx.$`${this.daemonPath} enable ${token}`;
        } catch (ex: any | ProcessOutput) {
            if (ex.stderr) {
                if (ex.stderr.includes("you already have an enabled environment")) {
                    return ex;
                }

                throw new Error(ex.stderr.trim());
            }

            const err = ex.stdout;
            if (err.includes("enableUnauthorized")) {
                throw new Error("Invalid Zrok token!");
            } else {
                const logger = getLogger("ZrokManager");
                logger.error(`Failed to set Zrok token! Error: ${err}`);
                throw new Error("Failed to set Zrok token! Please check your server logs for more information.");
            }
        }
    }

    static async reserve(name?: string): Promise<string> {
        const reservedTunnelToken = Server().repo.getConfig("zrok_reserved_token") as string;
        const logger = getLogger("ZrokManager");

        // If there is an existing token, release it.
        // We only want one reserved tunnel per person
        if (isNotEmpty(reservedTunnelToken)) {
            try {
                await ZrokManager.release(reservedTunnelToken);
            } catch (ex) {
                logger.debug(`Failed to release reserved Zrok tunnel! Error: ${ex}`);
            }
        }

        // Check if there are any existing reserved shares.
        // Rather than reserving a new one, we can just use the existing one.
        const existingToken = await ZrokManager.getExistingReservedShareToken(name);
        if (isNotEmpty(existingToken)) {
            await Server().repo.setConfig("zrok_reserved_token", existingToken);
            return existingToken;
        }

        try {
            const port = Server().repo.getConfig("socket_port") as string;
            const flags = [`0.0.0.0:${port}`, `--backend-mode`, `proxy`];

            if (isNotEmpty(name)) {
                flags.push(`--unique-name`);
                flags.push(name);
            }

            const result = await zx.$`${this.daemonPath} reserve public ${flags}`;
            const output = result.toString().trim();
            const urlMatches = output.match(ZrokManager.proxyUrlRegex);
            if (isEmpty(urlMatches)) {
                logger.debug(`Failed to reserve Zrok tunnel! Unable to find URL in output. Output: ${output}`);
                throw new Error(`Failed to reserve Zrok tunnel! Unable to find URL in output.`);
            }

            const regex = /reserved share token is '(?<token>[a-z0-9]+)'/g;
            const matches = Array.from(output.matchAll(regex));
            if (isEmpty(matches)) {
                logger.debug(`Failed to reserve Zrok tunnel! Unable to find token in output (1). Output: ${output}`);
                throw new Error(`Failed to reserve Zrok tunnel! Unable to find token in output.`);
            }

            const token = matches[0].groups?.token;
            if (isEmpty(token)) {
                logger.debug(`Failed to reserve Zrok tunnel! Unable to find token in output (2). Output: ${output}`);
                throw new Error(`Failed to reserve Zrok tunnel! Error: ${output}`);
            }

            await Server().repo.setConfig("zrok_reserved_token", token);
            return token;
        } catch (ex: any | ProcessOutput) {
            if (ex.stderr) {
                throw new Error(ex.stderr.trim());
            }

            const err = ex.stdout;
            if (err) {
                const logger = getLogger("ZrokManager");
                if (err.includes("shareInternalServerError")) {
                    throw new Error("Failed to reserve Zrok share! Internal server error! Share may be in use.");
                } else {
                    logger.error(`Failed to set Zrok token! Error: ${err}`);
                    throw new Error("Failed to set Zrok token! Please check your server logs for more information.");
                }
            }

            throw ex;
        }
    }

    static async disable(): Promise<ProcessOutput> {
        return await zx.$`${this.daemonPath} disable`;
    }

    static async getExistingReservedShareToken(name?: string): Promise<string | null> {
        // Run the overview command and parse the output
        const result = await zx.$`${this.daemonPath} overview`;
        const output = result.toString().trim();
        const json = JSON.parse(output);
        const host = Server().computerIdentifier;

        // Find the proper environment based on the computer user & name
        const env = (json.environments ?? []).find((e: any) => e.environment?.description === host);
        if (!env) return null;

        // Find an existing reserved share that matches our parameters
        const port = Server().repo.getConfig("socket_port") as string;
        const endpoint = `http://0.0.0.0:${port}`;
        const reserved = (env.shares ?? []).find(
            (s: any) =>
                s.shareMode === "public" &&
                s.backendMode === "proxy" &&
                s.backendProxyEndpoint === endpoint &&
                s.reserved === true &&
                // If a name is provided, make sure it matches
                (isEmpty(name) || s.token === name)
        );

        return reserved?.token ?? null;
    }

    static async release(token: string): Promise<ProcessOutput> {
        try {
            const result = await zx.$`${this.daemonPath} release ${token}`;

            // Clear the token from the config
            await Server().repo.setConfig("zrok_reserved_token", "");
            return result;
        } catch (ex: any | ProcessOutput) {
            if (ex.stderr) {
                if (ex.stderr.includes("unshareNotFound")) {
                    return ex;
                }

                throw new Error(ex.stderr.trim());
            }

            const err = ex.stdout ?? "Unknown";
            const logger = getLogger("ZrokManager");
            logger.error(`Failed to release Zrok share! Error: ${err}`);
            throw new Error("Failed to release Zrok share! Please check your server logs for more information.");
        }
    }
}
