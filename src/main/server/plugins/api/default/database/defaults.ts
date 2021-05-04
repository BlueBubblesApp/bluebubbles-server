import { Server } from "@server/index";
import { ConfigTypes, IConfig } from "./types";

export const ConfigOptions: IConfig = {
    setupComplete: {
        name: "setup_complete",
        type: ConfigTypes.BOOLEAN,
        default: () => false,
        getValue: () => Server().config.get("setupComplete")
    },
    autoStart: {
        name: "auto_start",
        type: ConfigTypes.BOOLEAN,
        default: () => false,
        getValue: (): boolean => Server().config.get("autoStart") as boolean
    },
    terminalStart: {
        name: "terminal_start",
        type: ConfigTypes.BOOLEAN,
        default: () => false,
        getValue: (): boolean => Server().config.get("terminalStart") as boolean
    },
    checkForUpdates: {
        name: "check_for_updates",
        type: ConfigTypes.BOOLEAN,
        default: () => true,
        getValue: (): boolean => Server().config.get("checkForUpdates") as boolean
    },
    autoUpdate: {
        name: "auto_update",
        type: ConfigTypes.BOOLEAN,
        default: () => false,
        getValue: (): boolean => Server().config.get("autoUpdate") as boolean
    }
};
