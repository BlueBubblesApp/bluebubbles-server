import { MinMaxMap } from "./types";

// Null means infinite
export const PluginTypeMinMaxMap: { [key: string]: MinMaxMap } = {
    ui: {
        min: 1,
        max: 1
    },
    tray: {
        min: 1,
        max: 1
    },
    messages_api: {
        min: 1,
        max: 1
    },
    general: {
        min: null as number,
        max: null as number
    },
    api: {
        min: 1,
        max: 5
    }, // This is a little bit arbitrary
    data_transformer: {
        min: 1,
        max: 1
    }
};
