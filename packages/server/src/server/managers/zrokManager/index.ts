import { isNotEmpty, isEmpty } from "@server/helpers/utils";
import { Loggable, getLogger } from "@server/lib/logging/Loggable";
import { FileSystem } from "@server/fileSystem";
import axios from "axios";
import { app } from "electron";
import { Server } from "@server";
import { spawn, ChildProcess } from "child_process";
import path from "path";
import { ProcessSpawner, ProcessSpawnerError } from "@server/lib/ProcessSpawner";

export class ZrokManager extends Loggable {
    tag = "ZrokManager";

    static get daemonPath() {
        return path.join(FileSystem.resources, "macos", "daemons", "zrok", (process.arch === "arm64") ? "arm64" : "x86", "zrok");
    }

    proc: ChildProcess;

    currentProxyUrl: string;

    isRestarting = false;

    static proxyUrlRegex = /\b(https:\/\/.*?\.zrok.io)\b/m;

    connectPromise: Promise<string> = null;

    isRateLimited = false;

    async start(): Promise<string> {
        if (this.isRateLimited) {
            throw new Error("Rate limited by Cloudflare. Waiting 1 hour before retrying...");
        }

        try {
            this.emit("started");
            return await this.connectHandler();
        } catch (ex) {
            this.log.error(`Failed to run Zrok daemon! ${ex.toString()}`);
            this.emit("error", ex);
        }

        return null;
    }

    private async connectHandler(): Promise<string> {
        const port = Server().repo.getConfig("socket_port") as string;
        const reservedTunnel = (Server().repo.getConfig("zrok_reserve_tunnel") as boolean) ?? false;
        const tunnelToken = await ZrokManager.reserve(null);

        return new Promise(async (resolve, reject) => {
            // Didn't use zx here because I couldn't figure out how to pipe the stdout
            // properly, without taking over the terminal outputs.
            // Conditionally change the command based on if we are reserving a tunnel or not
            const commndFlags = [
                "share",
                ...(reservedTunnel ? ["reserved", "--headless"] : ["public", "--backend-mode", "proxy", "--headless"]),
                ...(reservedTunnel ? [tunnelToken] : [`0.0.0.0:${port}`])
            ];

            if (this.proc && !this.proc?.killed) {
                this.log.debug("Zrok Tunnel already running. Stopping...");
                await this.stop();
            }

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
        const reservedTunnel = (Server().repo.getConfig("zrok_reserve_tunnel") as boolean) ?? false;
        const reservedToken = Server().repo.getConfig("zrok_reserved_token") as string;
        if (!reservedTunnel && isNotEmpty(reservedToken)) {
            await ZrokManager.safeRelease(reservedToken, { clearToken: true });
        }

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
        if (data.includes("dial tcp: lookup api-v1.zrok.io")) {
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
        const logger = getLogger("ZrokManager");

        try {
            logger.info(`Dispatching Zrok invite to ${email}...`);

            // Use axios to get the invite with the following spec
            await axios.post("https://api-v1.zrok.io/api/v1/invite", JSON.stringify({ email }), {
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

    static async setToken(token: string): Promise<string> {
        const logger = getLogger("ZrokManager");

        try {
            logger.info(`Enabling Zrok...`);
            return await ProcessSpawner.executeCommand(this.daemonPath, ["enable", token], {}, "ZrokManager");
        } catch (ex: any | ProcessSpawnerError) {
            const output = ex?.output ?? ex?.message ?? String(ex);
            if (output.includes("you already have an enabled environment")) {
                return output;
            } else if (output.includes("enableUnauthorized")) {
                throw new Error("Invalid Zrok token!");
            } else {
                logger.error(`Failed to set Zrok token! Error: ${output}`);
                throw new Error("Failed to set Zrok token! Please check your server logs for more information.");
            }
        }
    }

    static async reserve(name?: string): Promise<string> {
        const reservedTunnel = (Server().repo.getConfig("zrok_reserve_tunnel") as boolean) ?? false;
        const reservedToken = Server().repo.getConfig("zrok_reserved_token") as string;
        const reservedName = name ?? Server().repo.getConfig("zrok_reserved_name") as string;
        const logger = getLogger("ZrokManager");

        logger.info(`Looking for existing reserved Zrok share...`);
        const existingShare = await ZrokManager.getExistingReservedShareToken(reservedToken);
        const existingToken = existingShare?.shareToken;
        const existingIsReserved = existingShare?.reserved;

        if (existingShare) {
            logger.info(`Found existing reserved Zrok share: ${existingToken}`);
        } else {
            logger.debug(`No existing reserved Zrok share found.`);
        }

        // If we don't want to reserve a tunnel, clear the configs and release the existing token
        if (!reservedTunnel) {
            logger.debug(`Disabling reserved Zrok tunnel...`);
            await Server().repo.setConfig("zrok_reserved_token", "");
            await Server().repo.setConfig("zrok_reserved_name", "");

            // If there is an existing token, release it
            if (isNotEmpty(existingToken)) {
                logger.info(`Releasing existing Zrok share (${existingToken}) because we no longer want to use a reserved tunnel.`);
                await this.safeRelease(existingToken);
            }

            return null;
        }

        if (isNotEmpty(existingToken)) {
            logger.debug('Handling existing token...');

            // If the token is different, release the existing tunnel
            if (existingToken !== reservedToken) {
                logger.info(`Releasing existing Zrok share (${existingToken}) because the reserve token has changed.`);
                await ZrokManager.safeRelease(existingToken, { clearToken: true });
            // If the tokens match, but the name doesn't match the token (which will be the name),
            // then release the existing tunnel
            } else if (existingToken === reservedToken && isNotEmpty(reservedName) && reservedName !== existingToken) {
                logger.info(`Releasing existing Zrok share (${existingToken}) because the reserved name has changed.`);
                await ZrokManager.safeRelease(existingToken, { clearToken: true });
            // If we have an existing token and the name hasn't changed, return the existing token
            } else if (existingIsReserved) {
                logger.info(`Using existing Zrok token: ${existingToken}`);
                return existingToken;
            }
        }

        try {
            const port = Server().repo.getConfig("socket_port") as string;
            const flags = [`0.0.0.0:${port}`, `--backend-mode`, `proxy`];

            if (isNotEmpty(reservedName)) {
                flags.push(`--unique-name`);
                flags.push(reservedName);
            }

            logger.info(`Reserving new tunnel with flags: ${flags.join(" ")}`);
            const output = await ProcessSpawner.executeCommand(this.daemonPath, ["reserve", "public", ...flags], {}, "ZrokManager");
            const urlMatches = output.match(ZrokManager.proxyUrlRegex);
            if (isEmpty(urlMatches)) {
                logger.info(`Failed to reserve Zrok tunnel! Unable to find URL in output. Output: ${output}`);
                throw new Error(`Failed to reserve Zrok tunnel! Unable to find URL in output.`);
            }

            const regex = /reserved share token is '(?<token>[a-z0-9]+)'/g;
            const matches = Array.from(output.matchAll(regex));
            if (isEmpty(matches)) {
                logger.info(`Failed to reserve Zrok tunnel! Unable to find token in output (1). Output: ${output}`);
                throw new Error(`Failed to reserve Zrok tunnel! Unable to find token in output.`);
            }

            const token = matches[0].groups?.token;
            if (isEmpty(token)) {
                logger.info(`Failed to reserve Zrok tunnel! Unable to find token in output (2). Output: ${output}`);
                throw new Error(`Failed to reserve Zrok tunnel! Error: ${output}`);
            }

            await Server().repo.setConfig("zrok_reserved_token", token);
            return token;
        } catch (ex: any | ProcessSpawnerError) {
            const output = ex?.output ?? ex?.message ?? String(ex);
            const logger = getLogger("ZrokManager");
            if (output.includes("shareInternalServerError")) {
                throw new Error("Failed to reserve Zrok share! Internal server error! Share may be in use.");
            } else {
                logger.error(`Failed to set Zrok token! Error: ${output}`);
                throw new Error("Failed to set Zrok token! Please check your server logs for more information.");
            }
        }
    }

    static async disable(): Promise<string> {
        const logger = getLogger("ZrokManager");
        
        
        try {
            logger.debug("Disabling Zrok tunnel...");
            return await ProcessSpawner.executeCommand(this.daemonPath, ["disable"], {}, "ZrokManager");
        } catch (ex: any | ProcessSpawnerError) {
            const output = ex?.output ?? ex?.message ?? String(ex);
            logger.error(`Failed to disable Zrok tunnel! Error: ${output}`);
            throw new Error("Failed to disable Zrok tunnel! Please check your server logs for more information.");
        }
    }

    static async getExistingReservedShareToken(name?: string): Promise<any> {
        // Run the overview command and parse the output
        const output = await ProcessSpawner.executeCommand(this.daemonPath, ["overview"], {}, "ZrokManager");
        const json = JSON.parse(output);
        const host = Server().computerIdentifier;

        const logger = getLogger("ZrokManager");
        logger.debug(`Found ${json.environments.length} environments in Zrok overview`);

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
                (isEmpty(name) || s.shareToken === name)
        );

        return reserved;
    }

    static async safeRelease(token: string, { clearToken = false, clearName = false } = {}): Promise<string | null> {
        const logger = getLogger("ZrokManager");
        if (isNotEmpty(token)) {
            try {
                logger.info(`Releasing existing Zrok share with token: ${token}`);
                return await ZrokManager.release(token, { clearName, clearToken });
            } catch (ex) {
                logger.info(`Failed to release existing Zrok tunnel! Error: ${ex.toString()}`);
            }
        }

        return null;
    }

    static async release(token: string, { clearToken = false, clearName = false } = {}): Promise<string> {
        try {
            const logger = getLogger("ZrokManager");
            logger.info(`Releasing Zrok share with token: ${token}`);
            const result = await ProcessSpawner.executeCommand(this.daemonPath, ["release", token], {}, "ZrokManager");

            // Clear the token from the config
            if (clearToken) await Server().repo.setConfig("zrok_reserved_token", "");   
            if (clearName) await Server().repo.setConfig("zrok_reserved_name", "");
            return result;
        } catch (ex: any | ProcessSpawnerError) {
            const output = ex?.output ?? ex?.message ?? String(ex);
            const logger = getLogger("ZrokManager");
            if (output.includes("unshareNotFound")) {
                return output;
            }

            logger.error(`Failed to release Zrok share! Error: ${output}`);
            throw new Error("Failed to release Zrok share! Please check your server logs for more information.");
        }
    }
}
