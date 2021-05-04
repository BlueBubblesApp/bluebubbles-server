/* eslint-disable no-useless-constructor */
import { EventEmitter } from "events";

import { Server } from "@server/index";
import { PluginLogger } from "@server/logger/builtins/pluginLogger";

import { GlobalConfig } from "@server/databases/globalConfig";
import { IPluginConfig, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";

import { getPluginIdentifier } from "./helpers";

interface PluginBase {
    startup?(): Promise<void>;
    shutdown?(): Promise<void>;
    onGlobalConfigUpdate?(newConfig: GlobalConfig): Promise<void>;
    onConfigUpdate?(newConfig: IPluginConfig): Promise<void>;
    pluginWillLoad?(): Promise<void>;
    pluginDidLoad?(): Promise<void>;
    pluginWillUnload?(): Promise<void>;
    pluginDidUnload?(): Promise<void>;
    pluginWillUpdate?(currentConfig: IPluginConfig, nextConfig: IPluginConfig): Promise<void>;
    pluginDidUpdate?(): Promise<void>;
}

interface EventEmitterOptions {
    /**
     * Enables automatic capturing of promise rejection.
     */
    captureRejections?: boolean;
}

abstract class PluginBase extends EventEmitter {
    globalConfig: GlobalConfig;

    config: IPluginConfig;

    isRunning: boolean;

    logger: PluginLogger;

    get id(): string {
        return getPluginIdentifier(this.config.type, this.config.name);
    }

    get path(): string {
        return `${Server().appPath}/plugins/${this.id}`;
    }

    constructor(args: PluginConstructorParams, eventEmitterOptions?: EventEmitterOptions) {
        super(eventEmitterOptions);

        this.globalConfig = args.globalConfig;
        this.config = args.config;
        this.isRunning = false;

        this.logger = args.logger ?? new PluginLogger(`${this.config.type}.${this.config.name}`);
        this.globalConfig.on("update", (newGlobalConfig: GlobalConfig) => this.onGlobalConfigUpdate(newGlobalConfig));
    }

    getPlugin(identifier: string) {
        // First, let's see if the plugin is part of this plugin's dependencies
        // If not, throw an error. We want everyone to be disclosing the plugin dependencies they use
        const matches = (this.config.dependencies ?? []).filter(item => item === identifier);
        if (matches.length === 0) {
            throw new Error(`Failed to get plugin, ${identifier}; Plugin not a dependency!`);
        }

        // Next, let's find the plugin
        const plugin = Server().pluginManager.getPlugin(identifier);

        // Let's throw an error if it fails to get it
        if (!plugin) {
            throw new Error(`Failed to get plugin, ${identifier}`);
        }

        return plugin;
    }

    // eslint-disable-next-line class-methods-use-this
    getPluginsByType(type: IPluginTypes) {
        return Server().pluginManager.getPluginsByType(type);
    }

    getProperty(name: string, catchError = false): any {
        try {
            return Server().pluginManager.getPluginProperty(this.id, name);
        } catch (ex) {
            if (catchError) {
                throw ex;
            }
        }

        return null;
    }

    setProperty(name: string, value: any): any {
        return Server().pluginManager.setPluginProperty(this.id, name, value);
    }

    async initiate(): Promise<void> {
        this.isRunning = true;
        if (this.pluginWillLoad) await this.pluginWillLoad();
        if (this.startup) await this.startup();
        if (this.pluginDidLoad) await this.pluginDidLoad();
    }

    async configUpdate(newConfig: IPluginConfig): Promise<void> {
        if (this.pluginWillUpdate) await this.pluginWillUpdate(this.config, newConfig);
        this.config = newConfig;
        if (this.onConfigUpdate) await this.onConfigUpdate(newConfig);
        if (this.pluginDidUpdate) await this.pluginDidUpdate();
    }

    async destroy(): Promise<void> {
        if (this.pluginWillUnload) await this.pluginWillUnload();
        if (this.shutdown) await this.shutdown();
        if (this.pluginDidUnload) await this.pluginDidUnload();
    }
}

export { PluginBase };
