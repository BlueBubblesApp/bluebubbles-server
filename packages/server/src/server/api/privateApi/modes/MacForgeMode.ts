import CompareVersions from "compare-versions";
import cpr from "recursive-copy";
import { parse as ParsePlist } from "plist";

import { isMinBigSur, isMinMonterey } from "@server/env";
import { PrivateApiMode } from ".";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { restartMessages } from "@server/api/apple/scripts";


type BundleStatus = {
    success: boolean;
    message: string;
};


export class MacForgeMode extends PrivateApiMode {
    
    static async install(force = false) {
        const status: BundleStatus = { success: false, message: "Unknown status" };

        // Make sure the Private API is enabled
        const pApiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        if (!force && !pApiEnabled) {
            status.message = "Private API feature is not enabled";
            return status;
        }

        // eslint-disable-next-line no-nested-ternary
        const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";
        const localPath = path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.bundle");
        const localInfo = path.join(localPath, "Contents/Info.plist");

        // If the local bundle doesn't exist, don't do anything
        if (!fs.existsSync(localPath)) {
            status.message = "Unable to locate embedded bundle";
            return status;
        }

        Server().log("Attempting to install Private API Helper Bundle...", "debug");

        // Write to all paths. For MySIMBL & MacEnhance, as well as their user/library variants
        // Technically, MacEnhance is only for Mojave+, however, users may have older versions installed
        // If we find any of the directories, we should install to them
        const opts = [
            FileSystem.libMacForgePlugins,
            // FileSystem.usrMacForgePlugins,
            FileSystem.libMySimblPlugins
            // FileSystem.usrMySimblPlugins
        ];

        // For each of the paths, write the bundle to them (assuming the paths exist & the bundle is newer)
        let writeCount = 0;
        for (const pluginPath of opts) {
            // If the MacForge/MySIMBL path exists, but the plugin path doesn't, create it.
            if (fs.existsSync(path.dirname(pluginPath)) && !fs.existsSync(pluginPath)) {
                Server().log("Plugins path does not exist, creating it...", "debug");
                try {
                    fs.mkdirSync(pluginPath, { recursive: true });
                } catch (ex: any) {
                    Server().log(`Failed to create Plugins path: ${ex?.message ?? String(ex)}`, "debug");
                }
            }

            if (!fs.existsSync(pluginPath)) continue;

            const remotePath = path.join(pluginPath, "BlueBubblesHelper.bundle");
            const remoteInfo = path.join(remotePath, "Contents/Info.plist");

            try {
                // If the remote bundle doesn't exist, we just need to write it
                if (force || !fs.existsSync(remotePath)) {
                    if (force) {
                        Server().log(`Private API Bundle force install. Writing to ${remotePath}`, "debug");
                    } else {
                        Server().log(`Private API Bundle does not exist. Writing to ${remotePath}`, "debug");
                    }

                    await cpr(localPath, remotePath, { overwrite: true, dot: true });
                } else {
                    // Pull the version for the local bundle
                    let parsed = ParsePlist(fs.readFileSync(localInfo).toString("utf-8"));
                    let metadata = JSON.parse(JSON.stringify(parsed)); // We have to do this to access the vars
                    const localVersion = metadata.CFBundleShortVersionString;

                    // Pull the version for the remote bundle
                    parsed = ParsePlist(fs.readFileSync(remoteInfo).toString("utf-8"));
                    metadata = JSON.parse(JSON.stringify(parsed)); // We have to do this to access the vars
                    const remoteVersion = metadata.CFBundleShortVersionString;

                    // Compare the local version to the remote version and overwrite if newer
                    if (CompareVersions(localVersion, remoteVersion) === 1) {
                        Server().log(`Private API Bundle has an update. Writing to ${remotePath}`, "debug");
                        await cpr(localPath, remotePath, { overwrite: true, dot: true });
                    } else {
                        Server().log(`Private API Bundle does not need to be updated`, "debug");
                    }
                }

                writeCount += 1;
            } catch (ex: any) {
                Server().log(`Failed to write to ${remotePath}: ${ex?.message ?? ex}`);
            }
        }

        // Print a log based on if we wrote the bundle anywhere
        if (writeCount === 0) {
            status.message =
                "Attempted to install helper bundle, but neither MySIMBL nor MacForge (MacEnhance) was found!";
            Server().log(status.message, "warn");
        } else {
            // Restart iMessage to "apply" the changes
            Server().log("Restarting iMessage to apply Helper updates...");
            await FileSystem.executeAppleScript(restartMessages());

            status.success = true;
            status.message = "Successfully installed latest Private API Helper Bundle!";
            Server().log(status.message);
        }

        return status;
    }

    static async uninstall() {
        Server().log("Attempting to uninstall Private API Helper Bundle...", "debug");

        // Remove from all paths. For MySIMBL & MacEnhance, as well as their user/library variants
        // Technically, MacEnhance is only for Mojave+, however, users may have older versions installed
        // If we find any of the directories, we should install to them
        const opts = [
            FileSystem.libMacForgePlugins,
            // FileSystem.usrMacForgePlugins,
            FileSystem.libMySimblPlugins
            // FileSystem.usrMySimblPlugins
        ];

        for (const pluginPath of opts) {
            if (!fs.existsSync(pluginPath)) continue;

            const remotePath = path.join(pluginPath, "BlueBubblesHelper.bundle");

            try {
                // If the remote bundle doesn't exist, we just need to write it
                if (fs.existsSync(remotePath)) {
                    fs.rm(remotePath, { recursive: true, force: true });
                }
            } catch (ex: any) {
                Server().log((
                    `Failed to remove MacForge bundle at, "${remotePath}": ` +
                    `Please manually remove it to prevent conflicts`
                ), 'debug');
            }
        }
    }

    async start() {
        // Do nothing. This is managed by MacForge
    }

    async stop() {
        // Do nothing. This is managed by MacForge
    }
}