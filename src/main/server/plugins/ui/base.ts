import { PluginBase } from "@server/plugins/base";
import { BrowserWindow } from "electron";

interface UIPluginBase {
    loadIpcRoutes?(): void;
}

abstract class UIPluginBase extends PluginBase {
    window: BrowserWindow;

    async startup() {
        this.window = await this.createWindow();
        if (this.loadIpcRoutes) this.loadIpcRoutes();
    }

    async shutdown() {
        this.window.close();
        this.window.destroy();
        this.window = null;
    }

    abstract createWindow(): Promise<BrowserWindow>;
}

export { UIPluginBase };
