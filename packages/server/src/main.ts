import "reflect-metadata";
import "@server/env";

import { app, nativeTheme } from "electron";
import process from "process";
import fs from "fs";
import yaml from "js-yaml";
import { FileSystem } from "@server/fileSystem";
import { ParseArguments } from "@server/helpers/argParser";

import { Server } from "@server";
import { isEmpty, safeTrim } from "@server/helpers/utils";
import { AppWindow } from "@windows/AppWindow";
import { AppTray } from "@trays/AppTray";
import { getLogger } from "@server/lib/logging/Loggable";

app.commandLine.appendSwitch("in-process-gpu");

// Patch in original user data directory
app.setPath("userData", app.getPath("userData").replace("@bluebubbles/server", "bluebubbles-server"));

// Load the config file
let cfg = {};
if (fs.existsSync(FileSystem.cfgFile)) {
    cfg = yaml.load(fs.readFileSync(FileSystem.cfgFile, "utf8"));
}

// Parse the CLI args and marge with config args
const args = ParseArguments(process.argv);
const parsedArgs: Record<string, any> = { ...cfg, ...args };
let isHandlingExit = false;

// Initialize the server
Server(parsedArgs, null);
const log = getLogger("Main");

// Only 1 instance is allowed
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
    console.error("BlueBubbles is already running! Quiting...");
    app.exit(0);
} else {
    app.on("second-instance", (_, __, ___) => {
        if (Server().window) {
            if (Server().window.isMinimized()) Server().window.restore();
            Server().window.focus();
        }
    });

    // Start the Server() when the app is ready
    app.whenReady().then(() => {
        Server().start();
    });
}

process.on("uncaughtException", error => {
    // Print the exception
    log.error(`Uncaught Exception: ${error.message}`);
    if (error?.stack) log.debug(`Uncaught Exception StackTrace: ${error?.stack}`);
});

const handleExit = async (event: any = null, { exit = true } = {}) => {
    if (event) event.preventDefault();
    console.trace("handleExit");
    if (isHandlingExit) return;
    isHandlingExit = true;

    // Safely close the services
    if (Server() && !Server().isStopping) {
        await Server().stopServices();
    }

    if (exit) {
        app.exit(0);
    }
};

const createApp = () => {
    AppWindow.getInstance().setArguments(parsedArgs).build();
    AppTray.getInstance().setArguments(parsedArgs).setExitHandler(handleExit).build();
};

Server().on("update-available", _ => {
    AppTray.getInstance().build();
});

Server().on("ready", () => {
    createApp();
});

app.on("ready", () => {
    nativeTheme.on("updated", () => {
        AppTray.getInstance().build();
    });
});

app.on("activate", () => {
    if (Server().window == null && Server().repo) {
        AppWindow.getInstance().build();
    }
});

app.on("window-all-closed", () => {
    if (process.platform !== "darwin") {
        handleExit();
    }
});

/**
 * Basically, we want to gracefully exist whenever there is a Ctrl + C or other exit command
 */
app.on("before-quit", event => handleExit(event));

process.on("SIGTERM", async () => {
    log.debug("Received SIGTERM, exiting...");
    await handleExit(null, { exit: false });
});
process.on("SIGINT", async () => {
    log.debug("Received SIGINT, exiting...");
    await handleExit(null, { exit: false });
});

/**
 * All code below this point has to do with the command-line functionality.
 * This is when you run the app via terminal, we want to give users the ability
 * to still be able to interact with the app.
 */

const quickStrConvert = (val: string): string | number | boolean => {
    if (val.toLowerCase() === "true") return true;
    if (val.toLowerCase() === "false") return false;
    return val;
};

const handleSet = async (parts: string[]): Promise<void> => {
    const configKey = parts.length > 1 ? parts[1] : null;
    const configValue = parts.length > 2 ? parts[2] : null;
    if (!configKey || !configValue) {
        log.info("Empty config key/value. Ignoring...");
        return;
    }

    if (!Server().repo.hasConfig(configKey)) {
        log.info(`Configuration, '${configKey}' does not exist. Ignoring...`);
        return;
    }

    try {
        await Server().repo.setConfig(configKey, quickStrConvert(configValue));
        log.info(`Successfully set config item, '${configKey}' to, '${quickStrConvert(configValue)}'`);
    } catch (ex: any) {
        log.error(`Failed set config item, '${configKey}'\n${ex}`);
    }
};

const handleShow = async (parts: string[]): Promise<void> => {
    const configKey = parts.length > 1 ? parts[1] : null;
    if (!configKey) {
        log.info("Empty config key. Ignoring...");
        return;
    }

    if (!Server().repo.hasConfig(configKey)) {
        log.info(`Configuration, '${configKey}' does not exist. Ignoring...`);
        return;
    }

    try {
        const value = await Server().repo.getConfig(configKey);
        log.info(`${configKey} -> ${value}`);
    } catch (ex: any) {
        log.error(`Failed set config item, '${configKey}'\n${ex}`);
    }
};

const showHelp = () => {
    const help = `[================================== Help Menu ==================================]\n
Available Commands:
    - help:             Show the help menu
    - restart:          Relaunch/Restart the app
    - set:              Set configuration item -> \`set <config item> <value>\`
                        Available configuration items:
                            -> tutorial_is_done: boolean
                            -> socket_port: number
                            -> server_address: string
                            -> ngrok_key: string
                            -> password: string
                            -> auto_caffeinate: boolean
                            -> auto_start: boolean
                            -> enable_ngrok: boolean
                            -> encrypt_coms: boolean
                            -> hide_dock_icon: boolean
                            -> last_fcm_restart: number
                            -> start_via_terminal: boolean
    - show:             Show the current configuration for an item -> \`show <config item>\`
\n[===============================================================================]`;

    console.log(help);
};

process.stdin.on("data", chunk => {
    const line = safeTrim(chunk.toString());
    if (!Server() || isEmpty(line)) return;
    log.debug(`Handling STDIN: ${line}`);

    // Handle the standard input
    const parts = chunk ? line.split(" ") : [];
    if (isEmpty(parts)) {
        log.debug("Invalid command");
        return;
    }

    switch (parts[0].toLowerCase()) {
        case "help":
            showHelp();
            break;
        case "set":
            handleSet(parts);
            break;
        case "show":
            handleShow(parts);
            break;
        case "restart":
        case "relaunch":
            Server().relaunch();
            break;
        default:
            log.debug(`Unhandled command, '${parts[0]}'`);
    }
});
