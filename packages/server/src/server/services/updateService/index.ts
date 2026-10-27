import { app, BrowserWindow, dialog, MessageBoxOptions, Notification, shell } from "electron";
import { autoUpdater } from "electron-updater";
import * as semver from "semver";
import { Server } from "@server";
import { SERVER_UPDATE, SERVER_UPDATE_DOWNLOADING, SERVER_UPDATE_INSTALLING } from "@server/events";
import { ScheduledService } from "@server/lib/ScheduledService";
import { Loggable } from "@server/lib/logging/Loggable";
import axios, { AxiosResponse } from "axios";

const RELEASES_URL = "https://github.com/BlueBubblesApp/bluebubbles-server/releases";

export type AvailableUpdate = {
    version: string;
    releaseDate: string;
    releaseName: string;
    releaseNotes: any;
    url: string;
    // False when the release has no update metadata (latest-mac.yml),
    // so it can only be installed by downloading the DMG by hand
    canAutoInstall: boolean;
};

export class UpdateService extends Loggable {
    tag = "UpdateService";

    window: BrowserWindow;

    timer: ScheduledService;

    currentVersion: string;

    isOpen: boolean;

    isDownloading = false;

    hasUpdate = false;

    updateInfo: AvailableUpdate = null;

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

        // Downloads are started by installUpdate(), either from the user or the auto-install setting
        autoUpdater.logger = {
            info: (message?: any) => this.log.info(String(message)),
            // Before every macOS download, electron-updater runs `sysctl sysctl.proc_translated` to detect
            // Rosetta. Intel Macs don't have that key, so it always fails there and electron-updater warns,
            // which surfaces as a notification, then correctly carries on as not translated.
            warn: (message?: any) => {
                const text = String(message);
                if (text.includes("sysctl.proc_translated")) {
                    this.log.debug(text);
                } else {
                    this.log.warn(text);
                }
            },
            error: (message?: any) => this.log.error(String(message)),
            debug: (message: string) => this.log.debug(message)
        };
        autoUpdater.autoDownload = false;
        autoUpdater.autoInstallOnAppQuit = false;

        autoUpdater.on("update-downloaded", async _ => {
            this.log.info("Installing update...");
            await Server().emitMessage(SERVER_UPDATE_INSTALLING, null);
            autoUpdater.quitAndInstall();
        });

        // An unhandled "error" event would throw, so failures are logged here and by the callers
        autoUpdater.on("error", (err: Error) => {
            this.log.debug(`Auto-updater error: ${err?.message ?? String(err)}`);
        });
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
        const update = (await this.checkWithUpdater()) ?? (await this.checkWithGitHub());
        if (!update) return false;

        // Compare the latest version to the current version
        this.hasUpdate = semver.lt(this.currentVersion, semver.coerce(update.version).format());
        this.updateInfo = update;

        if (this.hasUpdate) {
            Server().emitMessage(SERVER_UPDATE, update.version);
            Server().emitToUI("update-available", update.version);
            Server().emit("update-available", update.version);

            const autoInstall = Server().repo.getConfig("auto_install_updates") as boolean;
            if (autoInstall && update.canAutoInstall) {
                this.log.info(`Auto-installing update v${update.version}...`);
                this.installUpdate();
            } else if (showUpdateDialog) {
                const notification = {
                    title: "BlueBubbles Update Available!",
                    body: `BlueBubbles macOS Server v${update.version} is now available to be installed!`
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

    /**
     * Downloads and installs the available update, relaunching the app when it's done.
     * Releases without update metadata can't be installed in place, so their release page is opened instead.
     */
    async installUpdate(): Promise<void> {
        if (!this.hasUpdate || !this.updateInfo) {
            this.log.debug("No update available to install!");
            return;
        }

        if (!this.updateInfo.canAutoInstall) {
            this.log.info(`v${this.updateInfo.version} can't be installed automatically, opening the release page...`);
            await shell.openExternal(this.updateInfo.url, { activate: true });
            return;
        }

        if (this.isDownloading) {
            this.log.debug("Update is already downloading!");
            return;
        }

        this.isDownloading = true;
        this.log.info(`Downloading update v${this.updateInfo.version}...`);
        Server().emitMessage(SERVER_UPDATE_DOWNLOADING, null);

        // Installation continues in the "update-downloaded" handler
        try {
            await autoUpdater.downloadUpdate();
        } catch (ex: any) {
            this.log.error(`Failed to download update! Error: ${ex?.message ?? String(ex)}`);
        } finally {
            this.isDownloading = false;
        }
    }

    /**
     * Checks the latest release's latest-mac.yml. Returns null when the app isn't packaged
     * or the release doesn't have one (every release before v1.9.10).
     */
    private async checkWithUpdater(): Promise<AvailableUpdate> {
        try {
            const res = await autoUpdater.checkForUpdates();
            if (!res?.updateInfo) return null;

            const info = res.updateInfo;
            return {
                version: info.version,
                releaseDate: info.releaseDate,
                releaseName: info.releaseName ?? `v${info.version}`,
                releaseNotes: info.releaseNotes,
                url: `${RELEASES_URL}/tag/v${info.version}`,
                canAutoInstall: true
            };
        } catch (ex: any) {
            const reason = ex?.message ?? String(ex);
            this.log.debug(`Update metadata unavailable, falling back to GitHub releases: ${reason}`);
            return null;
        }
    }

    private async checkWithGitHub(): Promise<AvailableUpdate> {
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
            return null;
        }

        const releases = (releasesRes.data as any[]).filter((x) =>
            !x.prerelease &&
            !x.draft &&
            x.tag_name.match(/v\d+\.\d+\.\d+/) &&
            x.assets.some((y: any) => y.name.startsWith('BlueBubbles-') && y.name.endsWith('.dmg'))
        );
        if (!releases || releases.length === 0) return null;

        const latest = releases[0];
        return {
            version: latest.tag_name.replace("v", ""),
            releaseDate: latest.published_at,
            releaseName: latest.name,
            releaseNotes: latest.body,
            url: latest.html_url,
            canAutoInstall: false
        };
    }
}
