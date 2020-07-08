import "reflect-metadata";
import { app, BrowserWindow, Tray, Menu } from "electron";
import * as path from "path";
import * as url from "url";

import { BlueBubblesServer } from "@server/index";
import { UpdateService } from "@server/services";
import trayIcon from "./assets/img/tray-icon.png";

let win: BrowserWindow | null;
let tray: Tray | null;
const api = new BlueBubblesServer(win);

// Start the API
api.start();

const buildTray = () => {
    return Menu.buildFromTemplate([
        {
            label: "BlueBubbles Server",
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
            label: "Restart",
            type: "normal",
            click: () => {
                app.relaunch({ args: process.argv.slice(1).concat(["--relaunch"]) });
                app.exit(0);
            }
        },
        {
            type: "separator"
        },
        {
            label: `Server Address: ${api.config?.server_address}`,
            enabled: false
        },
        {
            label: `Socket Connections: ${api.socketService?.socketServer.sockets.sockets.length ?? 0}`,
            enabled: false
        },
        {
            label: `Caffeinated: ${api.caffeinateService?.isCaffeinated}`,
            enabled: false
        },
        {
            type: "separator"
        },
        {
            label: "Close",
            type: "normal",
            click: () => {
                app.quit();
            }
        }
    ]);
};

const createTray = () => {
    tray = new Tray(path.join(__dirname, trayIcon));
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
        height: 1030,
        webPreferences: {
            nodeIntegration: true // Required in new electron version
        }
    });

    if (process.env.NODE_ENV !== "production") {
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

    if (process.env.NODE_ENV !== "production") {
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
    win.webContents.send("config-update", api.config);
    win.webContents.on("dom-ready", async () => {
        win.webContents.send("config-update", api.config);
    });

    // Set the new window in the API
    api.window = win;

    // Start the update service
    const updateService = new UpdateService();
    updateService.start();
    updateService.checkForUpdate();
};

app.on("ready", () => {
    createTray();
    createWindow();
});

app.on("window-all-closed", () => {
    if (process.platform !== "darwin") {
        app.quit();
    }
});

app.on("activate", () => {
    if (win === null) {
        createWindow();
    }
});
