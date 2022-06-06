import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { hideFindMyFriends, showApp, startFindMyFrields } from "@server/api/v1/apple/scripts";
import { waitMs } from "@server/helpers/utils";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FindMyService {

    static getDevices(): NodeJS.Dict<any> | null {
        const devicesPath = path.join(FileSystem.findMyDir, 'Devices.data');
        if (!fs.existsSync(devicesPath)) return null;

        const data = fs.readFileSync(devicesPath, { encoding: 'utf-8' });

        try {
            return JSON.parse(data);
        } catch (_) {
            return null;
        }
    }

    static async refresh(): Promise<NodeJS.Dict<any> | null> {
        const devicesPath = path.join(FileSystem.findMyDir, 'Devices.data');
        if (!fs.existsSync(devicesPath)) return null;

        // Make sure the Find My app is open.
        // Give it 3 seconds to open
        await FileSystem.executeAppleScript(startFindMyFrields());
        await waitMs(3000);

        // Bring the Find My app to the foreground so it refreshes the devices
        // Give it 5 seconods to refresh
        await FileSystem.executeAppleScript(showApp('FindMy'));
        await waitMs(5000);

        // Re-hide the Find My App
        await FileSystem.executeAppleScript(hideFindMyFriends()); 

        // Get the new locations
        return FindMyService.getDevices();
    }
}
