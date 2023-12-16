import * as process from "process";
import * as Keychain from "keychain";
import * as os from "os";
import { Server } from "@server";
import { isEmpty } from "@server/helpers/utils";
import { FileSystem } from "@server/fileSystem";

/**
 * Service that spawns the caffeinate process so that
 * the macOS operating system does not sleep until the server
 * exits.
 */
export class CallHistoryService {

    async verifySetup() {
        const isEnabled = Server().repo.getConfig('access_call_history') as boolean;
        const key = Server().repo.getConfig('call_history_db_key') as string;

        // If we are enabled, but there is no key, we need to disable the setting
        if (isEnabled && isEmpty(key)) {
            await Server().repo.setConfig('access_call_history', false);
        }
    }

    /**
     * Initializes the service and does some pre-checks
     */
    async init() {
        await this.verifySetup();
    }

    async getCallHistory() {
        const username = os.userInfo().username;
        console.log(username);
        Keychain.getPassword({
            service: 'Call History User Data Key',
            account: '',
        }, (err, pw) => {
            console.log(err);
            console.log(pw)
        })
        // const output = await FileSystem.executeAppleScript()
    }
}
