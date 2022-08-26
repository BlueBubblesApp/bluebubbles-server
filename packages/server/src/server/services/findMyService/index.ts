import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { hideFindMyFriends, showApp, startFindMyFrields } from "@server/api/v1/apple/scripts";
import { waitMs } from "@server/helpers/utils";
import { Server } from "@server";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FindMyService {

    private static cacheFileExists(guid: string): boolean {
        const cPath = path.join(FileSystem.findMyFriendsDir, "fsCachedData", guid);
        return fs.existsSync(cPath);
    }

    private static readCacheFile(guid: string): NodeJS.Dict<any> | null {
        if (!FindMyService.cacheFileExists(guid)) return null;
        const cPath = path.join(FileSystem.findMyFriendsDir, "fsCachedData", guid);
        const data = fs.readFileSync(cPath, { encoding: 'utf-8' });

        try {
            return JSON.parse(data);
        } catch {
            throw new Error('Failed to read FindMy cache file! It is not in the correct format!');
        }
    }

    static async getFriends(): Promise<NodeJS.Dict<any> | null> {
        // Initialize the DB connection if it hasn't been already
        const db = await Server().findMyRepo.initialize();

        // If we don't have a connection (maybe the DB doesn't exist),
        // return null because we want to indicate it's not capable
        if (!db) return null;

        // Get the references 
        const cacheRef = await Server().findMyRepo.getLatestCacheReference();
        if (!cacheRef) return null;

        // Read the corresponding cache file
        const guid = String(cacheRef.requestObject);
        return FindMyService.readCacheFile(guid);
    }

    static async refreshFriends(): Promise<NodeJS.Dict<any> | null> {
        await FindMyService.refresh();
        return await FindMyService.getFriends();
    }

    static getDevices(): NodeJS.Dict<any> | null {
        const devicesPath = path.join(FileSystem.findMyDir, 'Devices.data');
        if (!fs.existsSync(devicesPath)) return null;

        const data = fs.readFileSync(devicesPath, { encoding: 'utf-8' });

        try {
            return JSON.parse(data);
        } catch {
            throw new Error('Failed to read FindMy cache file! It is not in the correct format!');
        }
    }

    static async refresh(): Promise<void> {
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
    }

    static async refreshDevices(): Promise<NodeJS.Dict<any> | null> {
        const devicesPath = path.join(FileSystem.findMyDir, 'Devices.data');
        if (!fs.existsSync(devicesPath)) return null;

        await FindMyService.refresh();

        // Get the new locations
        return FindMyService.getDevices();
    }


}
