import * as path from "path";
import * as url from "url";
import { BrowserWindow } from "electron";

import { UIPluginBase } from "@server/plugins/ui/base";
import { IPluginConfig, IPluginConfigPropItemType, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";

const configuration: IPluginConfig = {
    name: "default",
    type: IPluginTypes.UI,
    displayName: "Default UI",
    description: "This is the default UI for BlueBubbles",
    version: 1,
    properties: [
        {
            name: "default_height",
            label: "Default Window Height",
            type: IPluginConfigPropItemType.NUMBER,
            group: "Window Settings",
            default: 750,
            description: "Adjust the default height for BlueBubbles Server window",
            required: true
        },
        {
            name: "default_witdth",
            label: "Default Window Width",
            type: IPluginConfigPropItemType.NUMBER,
            group: "Window Settings",
            default: 1080,
            description: "Adjust the default width for BlueBubbles Server window",
            required: true
        }
    ]
};

export default class DefaultUI extends UIPluginBase {
    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    async createWindow(): Promise<BrowserWindow> {
        const win = new BrowserWindow({
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

        const localOrGlobal = (): BrowserWindow => this.window ?? win;

        if (process.env.NODE_ENV === "development") {
            process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = "1"; // eslint-disable-line require-atomic-updates
            await win.loadURL(`http://localhost:2003`);
        } else {
            await win.loadURL(
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
                localOrGlobal().webContents.openDevTools();
            });
        }

        win.on("closed", () => {
            localOrGlobal().close();
            if (this.window) {
                this.window = null;
            }
        });

        // Prevent the title from being changed from BlueBubbles
        win.on("page-title-updated", evt => {
            evt.preventDefault();
        });

        return win;
    }

    static startIpcListener() {
        //     ipcMain.handle("get-message-count", async (event, args) => {
        //         if (!Server().iMessageRepo?.db) return 0;
        //         const count = await Server().iMessageRepo.getMessageCount(args?.after, args?.before, args?.isFromMe);
        //         return count;
        //     });
        //     ipcMain.handle("get-chat-image-count", async (event, args) => {
        //         if (!Server().iMessageRepo?.db) return 0;
        //         const count = await Server().iMessageRepo.getChatImageCounts();
        //         return count;
        //     });
        //     ipcMain.handle("get-chat-video-count", async (event, args) => {
        //         if (!Server().iMessageRepo?.db) return 0;
        //         const count = await Server().iMessageRepo.getChatVideoCounts();
        //         return count;
        //     });
        //     ipcMain.handle("get-group-message-counts", async (event, args) => {
        //         if (!Server().iMessageRepo?.db) return 0;
        //         const count = await Server().iMessageRepo.getChatMessageCounts("group");
        //         return count;
        //     });
        //     ipcMain.handle("get-individual-message-counts", async (event, args) => {
        //         if (!Server().iMessageRepo?.db) return 0;
        //         const count = await Server().iMessageRepo.getChatMessageCounts("individual");
        //         return count;
        //     });
        //     ipcMain.handle("get-devices", async (event, args) => {
        //         // eslint-disable-next-line no-return-await
        //         return await Server().db.devices().find();
        //     });
        //     ipcMain.handle("get-fcm-server", (event, args) => {
        //         return FileSystem.getFCMServer();
        //     });
        //     ipcMain.handle("get-fcm-client", (event, args) => {
        //         return FileSystem.getFCMClient();
        //     });
        // }
        // /**
        //  * Starts configuration related inter-process-communication handlers.
        //  */
        // static loadIpcRoutes() {
        //     ipcMain.handle("set-config", async (_, args) => {
        //         for (const item of Object.keys(args)) {
        //             if (Server().db.hasConfig(item) && Server().db.getConfig(item) !== args[item]) {
        //                 Server().db.setConfig(item, args[item]);
        //             }
        //         }
        //         return Server().db?.config;
        //     });
        //     ipcMain.handle("get-config", async (_, __) => {
        //         if (!Server().db.dbConn) return {};
        //         return Server().db?.config;
        //     });
        //     ipcMain.handle("get-alerts", async (_, __) => {
        //         const alerts = await AlertService.find();
        //         return alerts;
        //     });
        //     ipcMain.handle("mark-alert-as-read", async (_, args) => {
        //         const alertIds = args ?? [];
        //         // for (const id of alertIds) {
        //         //     await AlertService.markAsRead(id);
        //         // }
        //         await AlertService.markAsRead(args);
        //         Server().notificationCount = 0;
        //         app.setBadgeCount(Server().notificationCount);
        //     });
        //     ipcMain.handle("set-fcm-server", async (_, args) => {
        //         FileSystem.saveFCMServer(args);
        //     });
        //     ipcMain.handle("set-fcm-client", async (_, args) => {
        //         FileSystem.saveFCMClient(args);
        //         await Server().fcm.start();
        //     });
        //     ipcMain.handle("toggle-tutorial", async (_, toggle) => {
        //         await Server().db.setConfig("tutorial_is_done", toggle);
        //         if (toggle) {
        //             await Server().setupServices();
        //             await Server().startServices();
        //         }
        //     });
        //     ipcMain.handle("check_perms", async (_, __) => {
        //         return {
        //             abPerms: systemPreferences.isTrustedAccessibilityClient(false) ? "authorized" : "denied",
        //             fdPerms: Server().iMessageRepo?.db ? "authorized" : "denied"
        //         };
        //     });
        //     ipcMain.handle("prompt_accessibility", async (_, __) => {
        //         return {
        //             abPerms: systemPreferences.isTrustedAccessibilityClient(true) ? "authorized" : "denied"
        //         };
        //     });
        //     ipcMain.handle("prompt_disk_access", async (_, __) => {
        //         return {
        //             fdPerms: "authorized"
        //         };
        //     });
        //     ipcMain.handle("toggle-caffeinate", async (_, toggle) => {
        //         if (Server().caffeinate && toggle) {
        //             Server().caffeinate.start();
        //         } else if (Server().caffeinate && !toggle) {
        //             Server().caffeinate.stop();
        //         }
        //         await Server().db.setConfig("auto_caffeinate", toggle);
        //     });
        //     ipcMain.handle("toggle-ngrok", async (_, toggle) => {
        //         await Server().db.setConfig("enable_ngrok", toggle);
        //         if (Server().ngrok && toggle) {
        //             Server().ngrok.start();
        //         } else if (Server().ngrok && !toggle) {
        //             console.log("Stopping ngrok");
        //             Server().ngrok.stop();
        //             // Revert the server address to nothing
        //             await Server().db.setConfig("server_address", "Ngrok Disabled...");
        //         }
        //     });
        //     ipcMain.handle("get-caffeinate-status", (_, __) => {
        //         return {
        //             isCaffeinated: Server().caffeinate.isCaffeinated,
        //             autoCaffeinate: Server().db.getConfig("auto_caffeinate")
        //         };
        //     });
        //     ipcMain.handle("purge-event-cache", (_, __) => {
        //         if (Server().eventCache.size() === 0) {
        //             Server().log("No events to purge from event cache!");
        //         } else {
        //             Server().log(`Purging ${Server().eventCache.size()} items from the event cache!`);
        //             Server().eventCache.purge();
        //         }
        //     });
        //     ipcMain.handle("purge-devices", (_, __) => {
        //         Server().db.devices().clear();
        //     });
        //     ipcMain.handle("restart-via-terminal", (_, __) => {
        //         Server().restartViaTerminal();
        //     });
        //     ipcMain.handle("toggle-auto-start", async (_, toggle) => {
        //         await Server().db.setConfig("auto_start", toggle);
        //         app.setLoginItemSettings({ openAtLogin: toggle, openAsHidden: true });
        //     });
        //     ipcMain.handle("restart-server", async (_, __) => {
        //         await Server().hostRestart();
        //     });
        //     ipcMain.handle("get-current-theme", (_, __) => {
        //         if (nativeTheme.shouldUseDarkColors === true) {
        //             return {
        //                 currentTheme: "dark"
        //             };
        //         }
        //         return {
        //             currentTheme: "light"
        //         };
        //     });
        //     ipcMain.handle("show-dialog", (_, opts: Electron.MessageBoxOptions) => {
        //         return dialog.showMessageBox(Server().window, opts);
        //     });
        //     ipcMain.handle("open-log-location", (_, __) => {
        //         FileSystem.executeAppleScript(openLogs());
        //     });
        //     ipcMain.handle("clear-alerts", async (_, __) => {
        //         app.setBadgeCount(0);
        //         await Server().db.alerts().clear();
        //     });
    }
}
