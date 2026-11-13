import { app, BrowserWindow, dialog, MessageBoxOptions, Notification } from "electron";
import * as semver from "semver";
import { Server } from "@server";
import { SERVER_UPDATE } from "@server/events";
import { ScheduledService } from "@server/lib/ScheduledService";
import { Loggable } from "@server/lib/logging/Loggable";
import axios, { AxiosResponse } from "axios";

export class UpdateService extends Loggable {
    tag = "UpdateService";

    window: BrowserWindow;

    timer: ScheduledService;

    currentVersion: string;

    isOpen: boolean;

    hasUpdate = false;

    updateInfo: any;

    constructor(window: BrowserWindow) {
        super();

        // This won't work in dev-mode because it checks Electron's Version
        this.currentVersion = app.getVersion();
        this.isOpen = false;
        this.window = window;

        // Correct current version if needed
        if (this.currentVersion.split(".").length > 3) {
            this.currentVersion = semver.coerce(this.currentVersion).format();
        }
    }

    start() {
        if (this.timer) return;
        this.timer = new ScheduledService(async () => {
            if (this.hasUpdate) return;

            await this?.checkForUpdate();
        }, 1000 * 60 * 60 * 12); // Default 12 hours
    }

    stop() {
        if (this.timer) {
            this.timer.stop();
            this.timer = null;
        }
    }

    async checkForUpdate({ showNoUpdateDialog = false, showUpdateDialog = true } = {}): Promise<boolean> {
        let releasesRes: AxiosResponse<any, any>;

        try {
            releasesRes = await axios.get(
                "https://api.github.com/repos/BlueBubblesApp/bluebubbles-server/releases",
                {
                    headers: {
                        Accept: "application/vnd.github.v3+json"
                    }
                }
            );
        } catch (ex: any) {
            this.log.error(`Failed to fetch release information from GitHub! Error: ${ex?.message ?? String(ex)}`);
            return false;
        }

        const releases = (releasesRes.data as any[]).filter((x) =>
            !x.prerelease &&
            !x.draft &&
            x.tag_name.match(/v\d+\.\d+\.\d+/) &&
            x.assets.some((y: any) => y.name.startsWith('BlueBubbles-') && y.name.endsWith('.dmg'))
        );
        if (!releases || releases.length === 0) return false;
    
        // Get the version of the latest release
        const latest = releases[0];
        const latestVersion = latest.tag_name.replace("v", "");
        const semverVersion = semver.coerce(latestVersion).format();

        // Compare the latest version to the current version
        this.hasUpdate = semver.lt(this.currentVersion, semverVersion);
        this.updateInfo = latest;

        if (this.hasUpdate) {
            Server().emitMessage(SERVER_UPDATE, latestVersion);
            Server().emitToUI("update-available", latestVersion);
            Server().emit("update-available", latestVersion);

            if (showUpdateDialog) {
                const notification = {
                    title: "BlueBubbles Update Available!",
                    body: `BlueBubbles macOS Server v${latestVersion} is now available to be installed!`
                };
                new Notification(notification).show();
            }
        }

        if (!this.hasUpdate && showNoUpdateDialog) {
            const dialogOpts: MessageBoxOptions = {
                type: "info",
                title: "BlueBubbles Update",
                message: "You have the latest version installed!",
                detail: `You are running the latest version of BlueBubbles! v${this.currentVersion}`
            };

            dialog.showMessageBox(this.window, dialogOpts);
        }

        return this.hasUpdate;
    }
}
