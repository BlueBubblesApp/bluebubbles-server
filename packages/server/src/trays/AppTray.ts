import { autoUpdater } from "electron-updater";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { Tray } from ".";
import { SERVER_UPDATE_DOWNLOADING } from "@server/events";
import { Menu, nativeTheme, Tray as ElectronTray, app } from "electron";
import { AppWindow } from "@windows/AppWindow";
import path from "path";

export class AppTray extends Tray {
    private static self: AppTray;

    private exitHandler: () => Promise<void>;

    private arguments: Record<string, any> = {};

    private constructor() {
        super();
    }

    public static getInstance(): AppTray {
        if (!AppTray.self) {
            AppTray.self = new AppTray();
        }

        return AppTray.self;
    }

    setArguments(args: Record<string, any>): AppTray {
        this.arguments = args;
        return this;
    }

    setExitHandler(handler: () => Promise<void>): AppTray {
        this.exitHandler = handler;
        return this;
    }

    async build(): Promise<void> {
        let iconPath = path.join(FileSystem.resources, "macos", "icons", "tray-icon-dark.png");
        if (!nativeTheme.shouldUseDarkColors)
            iconPath = path.join(FileSystem.resources, "macos", "icons", "tray-icon-light.png");

        // If the this.instance is already created, just change the icon color
        if (this.instance) {
            this.instance.setImage(iconPath);
            return;
        }

        try {
            this.instance = new ElectronTray(iconPath);
            this.instance.setToolTip("BlueBubbles");
            this.instance.setContextMenu(this.buildMenu());

            // Rebuild the this.instance each time it's clicked
            this.instance.on("click", () => {
                this.instance.setContextMenu(this.buildMenu());
            });
        } catch (ex: any) {
            Server().log("Failed to load macOS this.instance entry!", "error");
            Server().log(ex?.message ?? String(ex), "debug");
        }
    }

    buildMenu(): Menu {
        const headless = (Server().repo?.getConfig("headless") as boolean) ?? false;
        const noGpu = (Server().repo?.getConfig("disable_gpu") as boolean) ?? false;
        let updateOpt: any = {
            label: "Check for Updates",
            type: "normal",
            click: async () => {
                if (Server()) {
                    await Server().updater.checkForUpdate({ showNoUpdateDialog: true });
                }
            }
        };

        if (Server()?.updater?.hasUpdate ?? false) {
            updateOpt = {
                label: `Install Update (${Server().updater.updateInfo.tag_name})`,
                type: "normal",
                click: async () => {
                    Server().emitMessage(SERVER_UPDATE_DOWNLOADING, null);
                    await autoUpdater.downloadUpdate();
                }
            };
        }

        return Menu.buildFromTemplate([
            {
                label: `BlueBubbles Server v${app.getVersion()}`,
                enabled: false
            },
            {
                label: "Open",
                type: "normal",
                click: () => {
                    if (Server().window && !Server().window.isDestroyed) {
                        Server().window.show();
                    } else {
                        AppWindow.getInstance().setArguments(this.arguments).build();
                    }
                }
            },
            updateOpt,
            {
                // The checkmark will cover when this is enabled
                label: `Headless Mode${headless ? " (Click to Disable)" : " (Click to Enable)"}`,
                type: "checkbox",
                checked: headless,
                click: async () => {
                    const toggled = !headless;
                    await Server().repo.setConfig("headless", toggled);
                    if (!toggled) {
                        AppWindow.getInstance().setArguments(this.arguments).build();
                    } else if (toggled && Server().window) {
                        Server().window.destroy();
                    }
                }
            },
            {
                // The checkmark will cover when this is enabled
                label: noGpu ? "Enable GPU Rendering" : "Disable GPU Rendering",
                click: async () => {
                    await Server().repo.setConfig("disable_gpu", !noGpu);
                    Server().relaunch();
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
                    if (this.exitHandler) {
                        await this.exitHandler();
                    }
                }
            }
        ]);
    }
}
