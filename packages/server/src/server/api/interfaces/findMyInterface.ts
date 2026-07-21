import { Server } from "@server";
import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { isMinSequoia } from "@server/env";
import { waitMs } from "@server/helpers/utils";
import { quitFindMyFriends, startFindMyFriends, showFindMyFriends, hideFindMyFriends } from "../apple/scripts";
import {
    FindMyDevice,
    FindMyFriendLocation,
    FindMyFriendsRefreshResponse,
    FindMyItem
} from "@server/api/lib/findmy/types";
import { normalizeFindMyFriendLocations, transformFindMyItemToDevice } from "@server/api/lib/findmy/utils";

export class FindMyInterface {
    static async getFriends(): Promise<FindMyFriendLocation[]> {
        return normalizeFindMyFriendLocations(Server().findMyCache.getAll());
    }

    static async getDevices(): Promise<Array<FindMyDevice> | null> {
        if (isMinSequoia) {
            Server().logger.debug("Cannot fetch FindMy devices on macOS Sequoia or later.");
            return null;
        }

        try {
            const [devices, items] = await Promise.all([
                FindMyInterface.readDataFile("Devices"),
                FindMyInterface.readDataFile("Items")
            ]);

            // Return null if neither of the files exist
            if (devices == null && items == null) return null;

            // Get any items with a group identifier
            const itemsWithGroup = items.filter(item => item.groupIdentifier);
            if (itemsWithGroup.length > 0) {
                try {
                    const itemGroups = await FindMyInterface.readItemGroups();
                    if (itemGroups) {
                        // Create a map of group IDs to group names
                        const groupMap = itemGroups.reduce((acc, group) => {
                            acc[group.identifier] = group.name;
                            return acc;
                        }, {} as Record<string, string>);

                        // Iterate over the items and add the group name
                        for (const item of items) {
                            if (item.groupIdentifier && groupMap[item.groupIdentifier]) {
                                item.groupName = groupMap[item.groupIdentifier];
                            }
                        }
                    }
                } catch (ex: any) {
                    Server().logger.debug("An error occurred while reading FindMy ItemGroups cache file.");
                    Server().logger.debug(String(ex));
                }
            }

            // Transform the items to match the same shape as devices
            const transformedItems = (items ?? []).map(transformFindMyItemToDevice);

            return [...(devices ?? []), ...transformedItems];
        } catch (ex: any) {
            Server().logger.debug("An error occurred while reading FindMy Device cache files.");
            Server().logger.debug(String(ex));
            return null;
        }
    }

    static async refreshDevices(): Promise<Array<FindMyDevice> | null> {
        await this.refreshUsingFindMyApp();
        return await this.getDevices();
    }

    static async refreshFriends(allowFindMyAppFallback = true): Promise<FindMyFriendLocation[]> {
        const privateApiEnabled = Boolean(Server().repo.getConfig("enable_private_api"));
        const findMyHelperAvailable = Server().privateApi.hasClient("com.apple.findmy");
        let receivedUsableHelperResponse = false;
        if (privateApiEnabled && isMinSequoia && findMyHelperAvailable) {
            try {
                const result = await Server().privateApi.findmy.refreshFriends();
                const refreshResponse = result?.data as FindMyFriendsRefreshResponse | undefined;
                if (Array.isArray(refreshResponse?.locations)) {
                    const refreshedLocations = normalizeFindMyFriendLocations(refreshResponse.locations);
                    receivedUsableHelperResponse = !refreshResponse.partial || refreshedLocations.length > 0;
                    Server().findMyCache.updateAll(refreshedLocations);

                    if (refreshResponse.partial) {
                        const timedOutFriendCount = Array.isArray(refreshResponse.timedOutHandles)
                            ? refreshResponse.timedOutHandles.length
                            : 0;
                        const skippedFriendCount = Number(refreshResponse.skippedFriends ?? 0);
                        Server().logger.warn(
                            `Find My Friends returned a partial response (${timedOutFriendCount} timed-out ` +
                                `handle(s), ${skippedFriendCount} skipped friend(s)).`
                        );
                    }
                }
            } catch (error: any) {
                Server().logger.warn(
                    `Unable to refresh Find My Friends through the helper: ${error?.message ?? String(error)}`
                );
            }
        }

        if (allowFindMyAppFallback && !receivedUsableHelperResponse) {
            void this.refreshUsingFindMyApp().catch((error: any) => {
                Server().logger.warn(`Unable to refresh Find My through the app: ${error?.message ?? String(error)}`);
            });
        }

        return normalizeFindMyFriendLocations(Server().findMyCache.getAll());
    }

    static async refreshUsingFindMyApp() {
        await FileSystem.requestFindMyAutomationPermissions();
        await FileSystem.executeAppleScript(quitFindMyFriends());
        await waitMs(3000);

        await FileSystem.executeAppleScript(startFindMyFriends());
        await waitMs(5000);

        await FileSystem.executeAppleScript(showFindMyFriends());
        await waitMs(15000);

        await FileSystem.executeAppleScript(hideFindMyFriends());
    }

    static async readItemGroups(): Promise<Array<any>> {
        const itemGroupsPath = path.join(FileSystem.findMyDir, "ItemGroups.data");
        if (!fs.existsSync(itemGroupsPath)) return [];

        return new Promise((resolve, reject) => {
            fs.readFile(itemGroupsPath, { encoding: "utf-8" }, (err, data) => {
                // Couldn't read the file
                if (err) return resolve(null);

                try {
                    const parsedData = JSON.parse(data.toString());
                    if (Array.isArray(parsedData)) {
                        return resolve(parsedData);
                    } else {
                        reject(new Error("Failed to read FindMy ItemGroups cache file! It is not an array!"));
                    }
                } catch {
                    reject(new Error("Failed to read FindMy ItemGroups cache file! It is not in the correct format!"));
                }
            });
        });
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
                    const parsedData = JSON.parse(data.toString());
                    if (Array.isArray(parsedData)) {
                        return resolve(parsedData);
                    } else {
                        reject(new Error(`Failed to read FindMy ${type} cache file! It is not an array!`));
                    }
                } catch {
                    reject(new Error(`Failed to read FindMy ${type} cache file! It is not in the correct format!`));
                }
            });
        });
    }
}
