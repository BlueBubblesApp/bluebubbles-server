export type CreatePluginParams = {
    name: string;
    enabled: boolean;
    displayName: string;
    type: string;
    description?: string;
    version?: number;
    properties?: object;
};

export type Scalar = Date | string | boolean | number;

export enum ConfigTypes {
    STRING = "string",
    DATE = "date",
    BOOLEAN = "boolean",
    NUMBER = "number",
    JSON = "json"
}

export type IConfig = {
    [key: string]: {
        name: string;
        type: ConfigTypes;
        default: () => any;
        getValue: () => any;
    };
};
