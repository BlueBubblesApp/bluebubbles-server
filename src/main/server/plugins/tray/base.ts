import { PluginBase } from "@server/plugins/base";
import { Menu, Tray } from "electron";

abstract class TrayPluginBase extends PluginBase {
    menu: Menu;

    tray: Tray;

    async startup() {
        this.menu = await this.buildMenu();
        this.tray = await this.createTray();
    }

    async shutdown() {
        this.menu = null;
        this.tray.closeContextMenu();
        this.tray.destroy();
        this.tray = null;
    }

    abstract buildMenu(): Promise<Menu>;

    abstract createTray(): Promise<Tray>;
}

export { TrayPluginBase };
