export class PluginRegistry {
    private static _instance: PluginRegistry;

    private plugins: any;

    private constructor() {
        this.plugins = {};
    }

    static get instance() {
        if (!this._instance) this._instance = new PluginRegistry();
        return this._instance;
    }

    registerPlugin(plugin: any) {
        if (!this.plugins[plugin.tag]) this.plugins[plugin.tag] = plugin;
    }

    getPlugin(tag: string) {
        return this.plugins[tag];
    }
}
