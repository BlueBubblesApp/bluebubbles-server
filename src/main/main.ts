import "reflect-metadata";
import { app, BrowserWindow, Tray, Menu, nativeTheme } from "electron";
import * as process from "process";
import * as path from "path";
import * as url from "url";
import { FileSystem } from "@server/fileSystem";

import { Server } from "@server/index";
import { UpdateService } from "@server/services";

let win: BrowserWindow;
let tray: Tray;
let api = Server(win);
let updateService: UpdateService;

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

    // Start the API when the app is ready
    app.whenReady().then(() => {
        api.start();
    });
}

const handleExit = async () => {
    if (!api) return;
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
                if (updateService) {
                    await updateService.checkForUpdate(true);
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
            label: `Server Address: ${api.repo?.getConfig("server_address")}`,
            enabled: false
        },
        {
            label: `Socket Connections: ${api.socket?.server.sockets.sockets.length ?? 0}`,
            enabled: false
        },
        {
            label: `Caffeinated: ${api.caffeinate?.isCaffeinated}`,
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
    let iconPath = path.join(FileSystem.resources, "macos", "tray-icon-dark.png");
    if (!nativeTheme.shouldUseDarkColors) iconPath = path.join(FileSystem.resources, "macos", "tray-icon-light.png");

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
        win.webContents.send("config-update", api.repo.config);
    });

    // Set the new window in the API
    api = Server(win);

    // Start the update service
    updateService = new UpdateService(win);

    Server().on("setup-complete", () => {
        const check = Server().repo.getConfig("check_for_updates") as boolean;
        if (check) {
            updateService.start();
            updateService.checkForUpdate(false);
        }
    });
};

app.on("ready", () => {
    createTray();
    createWindow();

    nativeTheme.on("updated", () => {
        createTray();
    });
});

app.on("window-all-closed", async () => {
    if (process.platform !== "darwin") {
        await handleExit();
    }
});

app.on("activate", () => {
    if (win === null) createWindow();
});

/**
 * I'm not totally sure this will work because of the way electron is...
 * But, I'm going to try.
 */
app.on("before-quit", async _ => {
    await handleExit();
});

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
    } catch (ex) {
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
\n[===============================================================================]`;

    console.log(help);
};

process.stdin.on("data", chunk => {
    const line = chunk.toString().trim();
    if (!api || !line || line.length === 0) return;
    Server().log(`Handling STDIN: ${line}`, "debug");

    // Handle the standard input
    const parts = chunk ? line.split(" ") : [];
    if (parts.length === 0) {
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
        case "restart":
        case "relaunch":
            Server().relaunch();
            break;
        default:
            Server().log(`Unhandled command, '${parts[0]}'`, "debug");
    }
});
