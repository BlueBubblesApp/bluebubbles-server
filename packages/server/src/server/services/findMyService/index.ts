import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import {
    hideFindMyFriends,
    startFindMyFriends,
    showFindMyFriends,
    quitFindMyFriends
} from "@server/api/apple/scripts";
import { waitMs } from "@server/helpers/utils";
import { Server } from "@server";
import { FindMyDevice, FindMyItem } from "@server/services/findMyService/types";
import { transformFindMyItemToDevice } from "@server/services/findMyService/utils";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FindMyService {
    // Unix timestamp in milliseconds
    static quitAppTime = 0;

    private static cacheFileExists(guid: string): boolean {
        const cPath = path.join(FileSystem.findMyFriendsDir, "fsCachedData", guid);
        return fs.existsSync(cPath);
    }

    private static readCacheFile(guid: string): NodeJS.Dict<any> | null {
        if (!FindMyService.cacheFileExists(guid)) return null;
        const cPath = path.join(FileSystem.findMyFriendsDir, "fsCachedData", guid);
        const data = fs.readFileSync(cPath, { encoding: "utf-8" });

        try {
            return JSON.parse(data);
        } catch {
            throw new Error("Failed to read FindMy cache file! It is not in the correct format!");
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

    static async refreshFriends(): Promise<void> {
        await FindMyService.refresh();
    }

    private static readDataFile<T extends "Devices" | "Items">(
        type: T
    ): Promise<Array<T extends "Devices" ? FindMyDevice : FindMyItem> | null> {
        const devicesPath = path.join(FileSystem.findMyDir, `${type}.data`);
        return new Promise((resolve, reject) => {
            fs.readFile(devicesPath, { encoding: "utf-8" }, (err, data) => {
                // Couldn't read the file
                if (err) return resolve(null);

                try {
                    return resolve(JSON.parse(data));
                } catch {
                    reject(new Error(`Failed to read FindMy ${type} cache file! It is not in the correct format!`));
                }
            });
        });
    }

    static async getDevices(): Promise<Array<FindMyDevice> | null> {
        try {
            const [devices, items] = await Promise.all([
                FindMyService.readDataFile("Devices"),
                FindMyService.readDataFile("Items")
            ]);

            // Return null if neither of the files exist
            if (!devices && !items) return null;

            // Transform the items to match the same shape as devices
            const transformedItems = (items ?? []).map(transformFindMyItemToDevice);

            return [...(devices ?? []), ...transformedItems];
        } catch {
            return null;
        }
    }

    static async refresh(): Promise<void> {
        const devicesPath = path.join(FileSystem.findMyDir, "Devices.data");
        if (!fs.existsSync(devicesPath)) return null;

        // Quit the FindMy app if it's been more than 2 minutes since the last refresh
        const now = new Date().getTime();
        if (now - FindMyService.quitAppTime > 120_000) {
            FindMyService.quitAppTime = now;
            await FileSystem.executeAppleScript(quitFindMyFriends());
            await waitMs(3000);
        }

        // Make sure the Find My app is open.
        // Give it 3 seconds to open
        await FileSystem.executeAppleScript(startFindMyFriends());
        await waitMs(3000);

        // Bring the Find My app to the foreground so it refreshes the devices
        // Give it 5 seconods to refresh
        await FileSystem.executeAppleScript(showFindMyFriends());
        await waitMs(5000);

        // Re-hide the Find My App
        await FileSystem.executeAppleScript(hideFindMyFriends());
    }

    static async refreshDevices(): Promise<NodeJS.Dict<any> | null> {
        const devicesPath = path.join(FileSystem.findMyDir, "Devices.data");
        if (!fs.existsSync(devicesPath)) return null;

        await FindMyService.refresh();

        // Get the new locations
        return await FindMyService.getDevices();
    }
}
