import { isEmpty } from "@server/helpers/utils";
import { Server } from "@server";


// This whole file was bascially cribbed from main.ts. I imagine the code should
// be consolidated and extracted somwhere.


function quickStrConvert (val: string) {
    if (val.toLowerCase() === "true") return true;
    if (val.toLowerCase() === "false") return false;
    return val;
}

async function handleSet (parts: string[]) {
    const configKey = parts.length > 1 ? parts[1] : null;
    const configValue = parts.length > 2 ? parts[2] : null;
    if (!configKey || !configValue) {
        return "Empty config key/value. Ignoring...";
    }

    if (!Server().repo.hasConfig(configKey)) {
        return `Configuration, '${configKey}' does not exist. Ignoring...`;
    }

    try {
        await Server().repo.setConfig(configKey, quickStrConvert(configValue));
        return `Successfully set config item, '${configKey}' to, '${quickStrConvert(configValue)}'`;
    } catch (ex: any) {
        Server().log(`Failed set config item, '${configKey}'\n${ex}`, "error");
        return `Failed set config item, '${configKey}'\n${ex}`;
    }
}

async function handleShow (parts: string[]) {
    const configKey = parts.length > 1 ? parts[1] : null;
    if (!configKey) {
        return "Empty config key. Ignoring...";
    }

    if (!Server().repo.hasConfig(configKey)) {
        return `Configuration, '${configKey}' does not exist. Ignoring...`;
    }

    try {
        const value = await Server().repo.getConfig(configKey);
        return `${configKey} -> ${value}`;
    } catch (ex: any) {
        Server().log(`Failed set config item, '${configKey}'\n${ex}`, "error");
        return `Failed set config item, '${configKey}'\n${ex}`;
    }
}

const help = `[================================== Help Menu ==================================]\n
Available Commands:
    - help:             Show the help menu
    - restart:          Relaunch/Restart the app
    - set:              Set configuration item -> \`set <config item> <value>\`
                        Available configuration items:
                            -> tutorial_is_done: boolean
                            -> socket_port: number
                            -> server_address: string
                            -> ngrok_key: string
                            -> password: string
                            -> auto_caffeinate: boolean
                            -> auto_start: boolean
                            -> enable_ngrok: boolean
                            -> encrypt_coms: boolean
                            -> hide_dock_icon: boolean
                            -> last_fcm_restart: number
                            -> start_via_terminal: boolean
    - show:             Show the current configuration for an item -> \`show <config item>\`
    - exit:             Exit the configurator
\n[===============================================================================]`;


export async function handleLine (line: string) : Promise<[string, boolean]> {
    line = line.trim();
    if (line === "") return ['', true];

    // Handle the standard input
    const parts = line.split(" ");
    if (isEmpty(parts)) return ['', true];

    if (!Server()) {
        return ["Server is not running???????", true];
    }

    switch (parts[0].toLowerCase()) {
        case "help":
            return [help, true];
        case "set":
            return [await handleSet(parts), true];
            break;
        case "show":
            return [await handleShow(parts), true];
            break;
        case "restart":
        case "relaunch":
            Server().relaunch();
            return ["Okay, restarting", true];
        case "exit":
            return ["Thank you for using the Bluebubbles configurator!", false];
        default:
            return ["Unrecognized command. Type 'help' for help.", true];
    }
}
