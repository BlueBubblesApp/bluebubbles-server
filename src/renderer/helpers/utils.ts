import { ipcRenderer } from "electron";

export const testJson = (value: string) => {
    try {
        return JSON.parse(value);
    } catch (ex) {
        return false;
    }
};

export const isValidClientConfig = (value: string): boolean => {
    const data = testJson(value);
    if (!data) return false;

    if (!Object.keys(data).includes("project_info")) return false;
    if (!Object.keys(data).includes("client")) return false;
    if (!Object.keys(data).includes("configuration_version")) return false;

    return true;
};

export const isValidServerConfig = (value: string): boolean => {
    const data = testJson(value);
    if (!data) return false;

    if (!Object.keys(data).includes("project_id")) return false;
    if (!Object.keys(data).includes("private_key_id")) return false;
    if (!Object.keys(data).includes("private_key")) return false;

    return true;
};

export const invokeMain = (event: string, args: any): Promise<any> => {
    return ipcRenderer.invoke(event, args);
};

export const checkFirebaseUrl = (config: { [key: string]: any }): boolean => {
    if (!config?.project_info?.firebase_url) {
        invokeMain("show-dialog", {
            type: "warning",
            buttons: ["OK"],
            title: "BlueBubbles Warning",
            message: "Please Enable Firebase's Realtime Database!",
            detail:
                `The client file you have loaded does not contain a Firebase URL! ` +
                `Please enable the Realtime Database in your Firebase Console, ` +
                `then re-download and re-load the configs.`
        });

        return false;
    }

    return true;
};
