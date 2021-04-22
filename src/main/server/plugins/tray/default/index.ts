import { app, BrowserWindow, Menu, Tray, nativeTheme } from "electron";
import * as path from "path";

import { FileSystem } from "@server/fileSystem";
import { TrayPluginBase } from "@server/plugins/tray/base";
import { IPluginConfig, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { BlueBubblesServer, Server } from "@server/index";
import DefaultUI from "@server/plugins/ui/default";

const configuration: IPluginConfig = {
    name: "default",
    type: IPluginTypes.TRAY,
    displayName: "Default Tray",
    description: "This is the default Tray for BlueBubbles",
    version: 1,
    properties: [],
    dependencies: ["ui.default"] // Other plugins this depends on (<type>.<name>)
};

export default class DefaultTray extends TrayPluginBase {
    interface: DefaultUI;

    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    getDefaultUI(): DefaultUI {
        if (this.interface) return this.interface;
        this.interface = this.getPlugin("ui.default") as DefaultUI;
        return this.interface;
    }

    getBrowserWindow(): BrowserWindow {
        const ui: DefaultUI = this.getDefaultUI();
        return ui.window;
    }

    // eslint-disable-next-line class-methods-use-this
    async buildMenu(): Promise<Menu> {
        return Menu.buildFromTemplate([
            {
                label: `BlueBubbles Server v${app.getVersion()}`,
                enabled: false
            },
            {
                label: "Open",
                type: "normal",
                click: () => {
                    const win = this.getBrowserWindow();
                    if (win) {
                        win.show();
                    } else {
                        const ui = this.getDefaultUI();
                        if (ui) {
                            ui.createWindow();
                        }
                    }
                }
            },
            {
                label: "Check for Updates",
                type: "normal",
                click: async () => {
                    // if (updateService) {
                    //     await updateService.checkForUpdate(true);
                    // }
                    // TODO: UPDATE SERVICE
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
            // {
            //     label: `Server Address: ${Server().repo?.getConfig("server_address")}`,
            //     enabled: false
            // },
            // {
            //     label: `Socket Connections: ${Server().socket?.server.sockets.sockets.length ?? 0}`,
            //     enabled: false
            // },
            // {
            //     label: `Caffeinated: ${Server().caffeinate?.isCaffeinated}`,
            //     enabled: false
            // },
            {
                type: "separator"
            },
            {
                label: "Close",
                type: "normal",
                click: async () => {
                    await this.handleExit();
                }
            }
        ]);
    }

    async createTray(): Promise<Tray> {
        let iconPath = path.join(FileSystem.resources, "macos", "tray-icon-dark.png");
        if (!nativeTheme.shouldUseDarkColors) {
            iconPath = path.join(FileSystem.resources, "macos", "tray-icon-light.png");
        }

        // If the tray is already created, just change the icon color
        if (this.tray) {
            this.tray.setImage(iconPath);
            return;
        }

        this.tray = new Tray(iconPath);
        this.tray.setToolTip("BlueBubbles");
        this.tray.setContextMenu(this.menu);

        // Rebuild the tray each time it's clicked
        this.tray.on("click", () => {
            this.tray.setContextMenu(this.menu);
        });
    }

    // eslint-disable-next-line class-methods-use-this
    async handleExit() {
        if (Server().isStopping) return;
        await Server().pluginManager.unloadPlugins();
        app.quit();
    }
}
