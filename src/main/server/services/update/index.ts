import { app, BrowserWindow, dialog } from "electron";
import { autoUpdater } from "electron-updater";
import { Server } from "@server/index";

export class UpdateService {
    window: BrowserWindow;

    timer: NodeJS.Timeout;

    currentVersion: string;

    isOpen: boolean;

    hasUpdate = false;

    constructor(window: BrowserWindow) {
        // This won't work in dev-mode because it checks Electron's Version
        this.currentVersion = app.getVersion();
        this.isOpen = false;
        this.window = window;

        autoUpdater.setFeedURL({
            provider: "github",
            owner: "BlueBubblesApp",
            repo: "BlueBubbles-Server",
            vPrefixedTagName: true,
            host: "github.com",
            protocol: "https",
            private: false,
            releaseType: "release"
        });
    }

    start() {
        this.timer = setInterval(async () => {
            if (this.hasUpdate) return;

            await this.checkForUpdate(false);
        }, 1000 * 60 * 60 * 12); // Default 12 hours
    }

    stop() {
        if (this.timer) clearInterval(this.timer);
    }

    async checkForUpdate(showDialogForNoUpdate: boolean): Promise<void> {
        const res = await autoUpdater.checkForUpdatesAndNotify();
        this.hasUpdate = !!res?.updateInfo;

        if (this.hasUpdate) {
            Server().emitMessage("server-update", res.updateInfo.version);

            if (Server().repo.getConfig("auto_install_updates") as boolean) {
                autoUpdater.on("update-downloaded", info => {
                    autoUpdater.quitAndInstall(false, true);
                });
            }
        }

        if (!this.hasUpdate && showDialogForNoUpdate) {
            const dialogOpts = {
                type: "info",
                title: "BlueBubbles Update",
                message: "You have the latest version installed!",
                detail: `You are running the latest version of BlueBubbles! v${this.currentVersion}`
            };

            dialog.showMessageBox(this.window, dialogOpts);
        }
    }
}
