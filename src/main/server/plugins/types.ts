import { GlobalConfig } from "@server/databases/globalConfig";
import { PluginLogger } from "@server/logger/builtins/pluginLogger";

export interface PluginBaseInterface {
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

    getPlugin(identifier: string): PluginBaseInterface;
}

export type IPluginConfigPropItemCondition = string[];

export type PluginConstructorParams = {
    globalConfig: GlobalConfig;
    config: IPluginConfig;
    logger?: PluginLogger;
};

export enum IPluginConfigPropItemType {
    STRING = "string",
    PASSWORD = "password",
    NUMBER = "number",
    BOOLEAN = "boolean",
    DATE = "date",
    JSON = "json",
    JSON_STRING = "json-string"
}

export enum IPluginTypes {
    UI = "ui",
    TRAY = "tray",
    GENERAL = "general",
    MESSAGES_DB = "messages_api",
    API = "api",
    DATA_TRANSFORMER = "data_transformer"
}

export type IPluginPropOption = {
    label: string;
    value: any;
    default?: boolean;
};

export type IPluginConfigPropItem = {
    name: string;
    label: string;
    type: IPluginConfigPropItemType;
    group?: string;
    value?: any;
    default?: any;
    options?: IPluginPropOption[];
    multiple?: boolean;
    placeholder?: string;
    description?: string;
    required?: boolean;
};

export type IPluginConfig = {
    name: string;
    type: IPluginTypes;
    displayName: string;
    description?: string;
    version: number;
    properties: IPluginConfigPropItem[];
    dependencies?: string[];
};

export type IPluginProperties = {
    enabled: boolean;
    properties: IPluginConfigPropItem[];
};

export type IPluginDBConfig = {
    [key: string]: IPluginProperties;
};

export type MinMaxMap = {
    min: number;
    max: number;
};

export type IdentifierInfo = {
    type: IPluginTypes;
    name: string;
};
