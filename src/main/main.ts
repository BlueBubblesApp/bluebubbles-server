import "reflect-metadata";
import { app, BrowserWindow, Tray, Menu, nativeTheme } from "electron";
import * as process from "process";
import * as path from "path";
import * as url from "url";
import { FileSystem } from "@server/fileSystem";

import { Server } from "@server/index";
import { isEmpty, safeTrim } from "@server/helpers/utils";

let win: BrowserWindow;
let tray: Tray;

app.allowRendererProcessReuse = false;

// Instantiate the server
Server(win);

// Only 1 instance is allowed
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
    console.error("BlueBubbles is already running! Quiting...");
    app.quit();
} else {
    app.on("second-instance", (_, __, ___) => {
        if (win) {
            if (win.isMinimized()) win.restore();
            win.focus();
        }
    });

    // Start the Server() when the app is ready
    app.whenReady().then(() => {
        Server().start();
    });
}

process.on("uncaughtException", error => {
    Server().log(`Uncaught Exception: ${error.message}`, "error");
});

const handleExit = async () => {
    if (!Server() || Server().isStopping) return;
    await Server().stopServices();
    app.quit();
};

const buildTray = () => {
    return Menu.buildFromTemplate([
        {
            label: `BlueBubbles Server v${app.getVersion()}`,
            enabled: false
        },
        {
            label: "Open",
            type: "normal",
            click: () => {
                if (win) {
                    win.show();
                } else {
                    createWindow();
                }
            }
        },
        {
            label: "Check for Updates",
            type: "normal",
            click: async () => {
                if (Server()) {
                    await Server().updater.checkForUpdate({ showNoUpdateDialog: true });
                }
            }
        },
        {
            label: "Restart",
            type: "normal",
            click: () => {
                Server().relaunch();
            }
        },
        {
            type: "separator"
        },
        {
            label: `Server Address: ${Server().repo?.getConfig("server_address")}`,
            enabled: false
        },
        {
            label: `Socket Connections: ${Server().httpService?.socketServer.sockets.sockets.size ?? 0}`,
            enabled: false
        },
        {
            label: `Caffeinated: ${Server().caffeinate?.isCaffeinated}`,
            enabled: false
        },
        {
            type: "separator"
        },
        {
            label: "Close",
            type: "normal",
            click: async () => {
                await handleExit();
            }
        }
    ]);
};

const createTray = () => {
    let iconPath = path.join(FileSystem.resources, "macos", "icons", "tray-icon-dark.png");
    if (!nativeTheme.shouldUseDarkColors)
        iconPath = path.join(FileSystem.resources, "macos", "icons", "tray-icon-light.png");

    // If the tray is already created, just change the icon color
    if (tray) {
        tray.setImage(iconPath);
        return;
    }

    tray = new Tray(iconPath);
    tray.setToolTip("BlueBubbles");
    tray.setContextMenu(buildTray());

    // Rebuild the tray each time it's clicked
    tray.on("click", () => {
        tray.setContextMenu(buildTray());
    });
};

const createWindow = async () => {
    win = new BrowserWindow({
        title: "BlueBubbles Server",
        useContentSize: true,
        width: 1080,
        minWidth: 800,
        height: 750,
        minHeight: 600,
        webPreferences: {
            nodeIntegration: true // Required in new electron version
        }
    });

    if (process.env.NODE_ENV === "development") {
        process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = "1"; // eslint-disable-line require-atomic-updates
        win.loadURL(`http://localhost:2003`);
    } else {
        win.loadURL(
            url.format({
                pathname: path.join(__dirname, "index.html"),
                protocol: "file:",
                slashes: true
            })
        );
    }

    if (process.env.NODE_ENV === "development") {
        // Open DevTools, see https://github.com/electron/electron/issues/12438 for why we wait for dom-ready
        win.webContents.once("dom-ready", () => {
            win!.webContents.openDevTools();
        });
    }

    win.on("closed", () => {
        win = null;
    });

    // Prevent the title from being changed from BlueBubbles
    win.on("page-title-updated", evt => {
        evt.preventDefault();
    });

    // Hook onto when we load the UI
    win.webContents.on("dom-ready", async () => {
        win.webContents.send("config-update", Server().repo.config);
    });

    // Set the new window in the Server()
    Server(win);
};

app.on("ready", () => {
    createTray();
    createWindow();

    nativeTheme.on("updated", () => {
        createTray();
    });
});

app.on("activate", () => {
    if (win === null) createWindow();
});

app.on("window-all-closed", () => {
    if (process.platform !== "darwin") {
        handleExit();
    }
});

/**
 * I'm not totally sure this will work because of the way electron is... but, I'm going to try.
 * Basically, we want to gracefully exist whenever there is a Ctrl + C or other exit command
 */
app.on("before-quit", () => handleExit());
app.on("will-quit", () => handleExit());
process.on("SIGINT", () => handleExit());

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
        Server().log("Empty config key/value. Ignoring...");
        return;
    }

    if (!Server().repo.hasConfig(configKey)) {
        Server().log(`Configuration, '${configKey}' does not exist. Ignoring...`);
        return;
    }

    try {
        await Server().repo.setConfig(configKey, quickStrConvert(configValue));
        Server().log(`Successfully set config item, '${configKey}' to, '${quickStrConvert(configValue)}'`);
    } catch (ex: any) {
        Server().log(`Failed set config item, '${configKey}'\n${ex}`, "error");
    }
};

const handleShow = async (parts: string[]): Promise<void> => {
    const configKey = parts.length > 1 ? parts[1] : null;
    if (!configKey) {
        Server().log("Empty config key. Ignoring...");
        return;
    }

    if (!Server().repo.hasConfig(configKey)) {
        Server().log(`Configuration, '${configKey}' does not exist. Ignoring...`);
        return;
    }

    try {
        const value = await Server().repo.getConfig(configKey);
        Server().log(`${configKey} -> ${value}`);
    } catch (ex: any) {
        Server().log(`Failed set config item, '${configKey}'\n${ex}`, "error");
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
    Server().log(`Handling STDIN: ${line}`, "debug");

    // Handle the standard input
    const parts = chunk ? line.split(" ") : [];
    if (isEmpty(parts)) {
        Server().log("Invalid command", "debug");
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
            Server().log(`Unhandled command, '${parts[0]}'`, "debug");
    }
});
