import { Server } from "@server";
import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur, isMinSequoia, isMinSonoma } from "@server/env";
import { waitMs } from "@server/helpers/utils";
import { quitFindMyFriends, startFindMyFriends, showFindMyFriends, hideFindMyFriends } from "../apple/scripts";
import {
    FindMyDevice,
    FindMyDevicesRefreshResponse,
    FindMyFriendLocation,
    FindMyFriendsRefreshResponse,
    FindMyItem
} from "@server/api/lib/findmy/types";
import {
    normalizeFindMyDevices,
    normalizeFindMyFriendLocations,
    transformFindMyItemToDevice
} from "@server/api/lib/findmy/utils";
import {
    resolveFindMyDevicesPrivateApiTarget,
    resolveFindMyFriendsPrivateApiTarget
} from "@server/api/lib/findmy/privateApiSupport";

import { FindMyUnavailableError } from "@server/api/privateApi/FindMyHelperReadiness";

const FIND_MY_DEVICES_HELPER_CONNECTION_TIMEOUT_MS = 10_000;
const FIND_MY_DEVICES_HELPER_CONNECTION_POLL_MS = 100;

export class FindMyInterface {
    static async getFriends(): Promise<FindMyFriendLocation[]> {
        return normalizeFindMyFriendLocations(Server().findMyFriendsCache.getAll());
    }

    static async getDevices(): Promise<Array<FindMyDevice> | null> {
        if (isMinSequoia) {
            return Server().findMyDevicesCache.getAll();
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
        if (isMinSequoia) {
            return this.refreshDevicesThroughPrivateApi();
        }

        await this.refreshUsingFindMyApp();
        return this.getDevices();
    }

    private static async refreshDevicesThroughPrivateApi(): Promise<FindMyDevice[]> {
        const privateApiEnabled = Boolean(Server().repo.getConfig("enable_private_api"));
        if (!privateApiEnabled) {
            throw new Error("Find My Devices on macOS 15 or later requires the Private API");
        }

        const openFindMyOnStartup = Boolean(Server().repo.getConfig("open_findmy_on_startup"));
        if (!openFindMyOnStartup) {
            throw new Error("Find My Devices requires Open FindMy App on Startup to be enabled");
        }

        const targetProcessIdentifier = resolveFindMyDevicesPrivateApiTarget({ isMinSequoia });
        if (targetProcessIdentifier == null) {
            throw new Error("The Find My Devices helper is unavailable on this macOS version");
        }

        await FileSystem.execShellCommand("/usr/bin/open findmy://devices");
        const helperAvailable = await this.waitForPrivateApiClient(targetProcessIdentifier);
        if (!helperAvailable) {
            throw new Error("The Find My Devices helper did not connect before the refresh timeout");
        }

        const result = await Server().privateApi.findmy.refreshDevices();
        const refreshResponse = result?.data as FindMyDevicesRefreshResponse | undefined;
        if (!Array.isArray(refreshResponse?.devices)) {
            throw new Error("The Find My Devices helper returned an invalid response");
        }
        if (typeof refreshResponse.partial !== "boolean") {
            throw new Error("The Find My Devices helper returned an invalid completion state");
        }
        const skippedDeviceCount = refreshResponse.skippedDevices;
        if (typeof skippedDeviceCount !== "number" || !Number.isInteger(skippedDeviceCount) || skippedDeviceCount < 0) {
            throw new Error("The Find My Devices helper returned an invalid skipped-device count");
        }
        if (refreshResponse.partial !== skippedDeviceCount > 0) {
            throw new Error("The Find My Devices helper returned an inconsistent completion state");
        }

        const devices = normalizeFindMyDevices(refreshResponse.devices);
        if (devices.length !== refreshResponse.devices.length) {
            throw new Error("The Find My Devices helper returned invalid device records");
        }

        const deviceIdentifiers = devices.map(device => device.identifier);
        if (new Set(deviceIdentifiers).size !== deviceIdentifiers.length) {
            throw new Error("The Find My Devices helper returned duplicate device identifiers");
        }

        if (refreshResponse.partial) {
            Server().findMyDevicesCache.updateAll(devices);
            Server().logger.warn(
                `Find My Devices returned a partial response (${skippedDeviceCount} ` + "unidentifiable device(s))."
            );
        } else {
            Server().findMyDevicesCache.replaceAll(devices);
        }

        const devicesWithLocations = devices.filter(device => device.location != null).length;
        Server().logger.debug(
            `Refreshed ${devices.length} Find My device(s) through FMIPDataManager; ` +
                `${devicesWithLocations} included a location.`
        );
        return Server().findMyDevicesCache.getAll();
    }

    private static async waitForPrivateApiClient(processIdentifier: string): Promise<boolean> {
        const maximumAttempts = Math.ceil(
            FIND_MY_DEVICES_HELPER_CONNECTION_TIMEOUT_MS / FIND_MY_DEVICES_HELPER_CONNECTION_POLL_MS
        );
        for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
            if (Server().privateApi.hasClient(processIdentifier)) {
                return true;
            }
            await waitMs(FIND_MY_DEVICES_HELPER_CONNECTION_POLL_MS);
        }
        return Server().privateApi.hasClient(processIdentifier);
    }

    private static requireFindMyHelperReady(processIdentifier: string): void {
        const api = Server().privateApi;
        const readiness = api.findMyReadiness;
        if (readiness.status !== "ready" || !api.hasClient(processIdentifier)) {
            throw new FindMyUnavailableError(
                readiness.status === "ready"
                    ? {
                          ...readiness,
                          status: "unavailable",
                          reason: "connection_lost",
                          message: "Find My helper is not connected. Retry to check its availability again."
                      }
                    : readiness
            );
        }
    }

    static async refreshFriends(
        allowFindMyAppFallback = true,
        requireFreshResult = false
    ): Promise<FindMyFriendLocation[]> {
        const privateApiEnabled = Boolean(Server().repo.getConfig("enable_private_api"));
        const privateApiTarget = resolveFindMyFriendsPrivateApiTarget({ isMinBigSur, isMinSonoma, isMinSequoia });
        const privateApiHelperAvailable = privateApiTarget != null && Server().privateApi.hasClient(privateApiTarget);
        if (isMinSequoia && (Server().privateApi.findMyReadiness.status !== "ready" || !privateApiHelperAvailable)) {
            if (requireFreshResult && privateApiTarget) this.requireFindMyHelperReady(privateApiTarget);
            return this.getFriends();
        }
        let receivedUsableHelperResponse = false;
        if (privateApiEnabled && privateApiTarget != null && privateApiHelperAvailable) {
            try {
                const result = await Server().privateApi.findmy.refreshFriends();
                const refreshResponse = result?.data as FindMyFriendsRefreshResponse | undefined;
                if (Array.isArray(refreshResponse?.locations)) {
                    const refreshedLocations = normalizeFindMyFriendLocations(refreshResponse.locations);
                    if (refreshedLocations.length !== refreshResponse.locations.length) {
                        throw new Error("The Find My Friends helper returned invalid location records");
                    }
                    const handles = refreshedLocations.map(location => location.handle);
                    if (new Set(handles).size !== handles.length) {
                        throw new Error("The Find My Friends helper returned duplicate friend handles");
                    }

                    // The dedicated helper reports whether its snapshot is complete.
                    // Earlier Messages helpers do not supply this metadata.
                    if (isMinSequoia) {
                        if (
                            typeof refreshResponse.partial !== "boolean" ||
                            typeof refreshResponse.friendListTimedOut !== "boolean" ||
                            !Array.isArray(refreshResponse.timedOutHandles) ||
                            !refreshResponse.timedOutHandles.every(
                                handle => typeof handle === "string" && handle.trim().length > 0
                            ) ||
                            !Number.isInteger(refreshResponse.skippedFriends) ||
                            refreshResponse.skippedFriends < 0
                        ) {
                            throw new Error("The Find My Friends helper returned invalid completion metadata");
                        }
                        if (
                            !refreshResponse.partial &&
                            (refreshResponse.friendListTimedOut ||
                                refreshResponse.timedOutHandles.length > 0 ||
                                refreshResponse.skippedFriends > 0)
                        ) {
                            throw new Error("The Find My Friends helper returned an inconsistent completion state");
                        }
                    }
                    const responseIsPartial = refreshResponse.partial === true;
                    if (responseIsPartial) {
                        Server().findMyFriendsCache.updateAll(refreshedLocations);
                    } else {
                        Server().findMyFriendsCache.replaceAll(refreshedLocations);
                    }
                    receivedUsableHelperResponse = !responseIsPartial || refreshedLocations.length > 0;

                    if (responseIsPartial) {
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

        if (requireFreshResult && isMinSequoia && !receivedUsableHelperResponse) {
            throw new Error("Find My Friends helper did not return a usable fresh response; cached data was retained");
        }

        const shouldRefreshUsingFindMyApp = allowFindMyAppFallback && (!receivedUsableHelperResponse || !isMinSequoia);
        if (shouldRefreshUsingFindMyApp) {
            void this.refreshUsingFindMyApp().catch((error: any) => {
                Server().logger.warn(`Unable to refresh Find My through the app: ${error?.message ?? String(error)}`);
            });
        }

        return normalizeFindMyFriendLocations(Server().findMyFriendsCache.getAll());
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
