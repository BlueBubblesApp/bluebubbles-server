import { Server } from "@server";
import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur, isMinSequoia, isMinSonoma } from "@server/env";
import { checkPrivateApiStatus, waitMs } from "@server/helpers/utils";
import { quitFindMyFriends, startFindMyFriends, showFindMyFriends, hideFindMyFriends } from "../apple/scripts";
import { FindMyDevice, FindMyItem, FindMyLocationItem } from "@server/api/lib/findmy/types";
import { transformFindMyItemToDevice } from "@server/api/lib/findmy/utils";
import {
    assertFindMyLocationsFresh,
    assertFindMyLocationsUsable,
    loadBeaconStoreKey,
    readFindMyFriendsFromSecureCache,
    supportsSecureLocationCacheReader
} from "@server/api/lib/findmy/SecureLocationReader";
import { startBackgroundFindMyRefresh } from "@server/api/lib/findmy/BackgroundFindMyRefresh";
import { PrivateApiFindMyEventHandler } from "@server/api/privateApi/eventHandlers/PrivateApiFindMyEventHandler";
import { FindMyAddressLabeler, createAppleGeocodeBatch } from "@server/api/lib/findmy/AppleReverseGeocoder";

export class FindMyInterface {
    // Shared so the coordinate-cell cache survives between refreshes. Created lazily because
    // `FileSystem.resources` depends on the app path, which is only known after Electron starts.
    private static labeler: FindMyAddressLabeler | null = null;

    private static getLabeler(): FindMyAddressLabeler | null {
        if (!this.labeler && fs.existsSync(FileSystem.findMyReverseGeocoder)) {
            this.labeler = new FindMyAddressLabeler(createAppleGeocodeBatch(FileSystem.findMyReverseGeocoder));
        }

        return this.labeler;
    }

    /**
     * Publishes locations with a "City, ST" address in place of Apple's missing label.
     * Locations the geocoder could not place keep their coordinates as the address.
     * Coordinates are geocoded only through Apple's on-device CLGeocoder via the packaged
     * helper. The cache drops a labelled copy whose coordinates have since been superseded.
     */
    private static async publishWithAddresses(locations: FindMyLocationItem[]): Promise<void> {
        const labeler = this.getLabeler();
        const labeled = labeler
            ? await labeler.labelWithin(locations, 3000)
            : { current: locations, late: null };
        const handler = new PrivateApiFindMyEventHandler();
        await handler.handleNewLocation(labeled.current);
        if (labeled.late) {
            void labeled.late.then(late => handler.handleNewLocation(late)).catch(() => undefined);
        }
    }

    static async getFriends() {
        return Server().findMyCache.getAll();
    }

    static async getDevices(): Promise<Array<FindMyDevice> | null> {
        if (isMinSequoia) {
            Server().logger.debug('Cannot fetch FindMy devices on macOS Sequoia or later.');
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
                    Server().logger.debug('An error occurred while reading FindMy ItemGroups cache file.');
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
        // Can't use the Private API to refresh devices yet
        await this.refreshLocationsAccessibility();
        return await this.getDevices();
    }

    static async refreshFriends(openFindMyApp = true): Promise<FindMyLocationItem[]> {
        let refreshedFindMyApp = false;
        // Find My's roster is authoritative for identity, favorites, and removals.
        Server().findMyCache.refreshRoster(true);

        // Before Sonoma, searchpartyd keeps current friend locations in its encrypted
        // SecureLocationCache. Prefer that direct source over the opportunistic
        // Messages/FMFSessions event cache, which has no on-demand refresh. Sonoma 14.4+
        // uses a different encrypted storage path and must be handled separately.
        if (
            supportsSecureLocationCacheReader(isMinSonoma) &&
            fs.existsSync(FileSystem.findMySecureLocationsDir) &&
            fs.existsSync(FileSystem.findMyFriendCachePath)
        ) {
            const readDirectLocations = () =>
                readFindMyFriendsFromSecureCache(
                    FileSystem.findMySecureLocationsDir,
                    FileSystem.findMyFriendCachePath,
                    loadBeaconStoreKey(),
                    (name, error) => {
                        Server().logger.debug(`Failed to decrypt SecureLocationCache record ${name}.`);
                        Server().logger.debug(String(error));
                    }
                );

            // The AppleScript bounce takes about 25 seconds, while the Android friends
            // endpoint uses the normal API timeout. Return the best current snapshot
            // immediately, refresh in the background, then publish changed locations
            // over the socket path the client already listens to.
            if (openFindMyApp) {
                startBackgroundFindMyRefresh(
                    () => this.refreshLocationsAccessibility(),
                    readDirectLocations,
                    async locations => {
                        assertFindMyLocationsFresh(locations);
                        await this.publishWithAddresses(locations);
                    },
                    error => {
                        Server().logger.debug("Failed to refresh Find My friends from SecureLocationCache.");
                        Server().logger.debug(String(error));
                    },
                    async () => {
                        await FileSystem.executeAppleScript(quitFindMyFriends());
                    }
                );
                refreshedFindMyApp = true;
            }

            try {
                const directLocations = readDirectLocations();
                assertFindMyLocationsUsable(directLocations);
                // Wait briefly for cities so the response carries them. Anything slower
                // (e.g. a cold cache after restart) shows coordinates and follows over the socket.
                const labeler = this.getLabeler();
                const labeled = labeler
                    ? await labeler.labelWithin(directLocations, 3000)
                    : { current: directLocations, late: null };
                Server().findMyCache.addAll(labeled.current);
                if (labeled.late) {
                    void labeled.late
                        .then(late => new PrivateApiFindMyEventHandler().handleNewLocation(late))
                        .catch(() => undefined);
                }

                return Server().findMyCache.getAll();
            } catch (ex: any) {
                // Fall through to the Messages/FMFSessions path below. On Monterey that path
                // has no on-demand refresh and usually returns stale data, but returning
                // whatever it holds beats failing the request outright.
                Server().logger.debug("Failed to read Find My friends from SecureLocationCache.");
                Server().logger.debug(String(ex));
            }
        }

        const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        if (papiEnabled && isMinBigSur && !isMinSonoma) {
            checkPrivateApiStatus();
            const result = await Server().privateApi.findmy.refreshFriends();
            const refreshLocations = result?.data?.locations ?? [];

            // Save the data to the cache
            // The cache will handle properly updating the data.
            Server().findMyCache.addAll(refreshLocations);
        }

        // No matter what, open the Find My app.
        // Don't await because it should update in the background.
        // Location updates get emitted as an event as they come in.
        if (openFindMyApp && !refreshedFindMyApp) {
            this.refreshLocationsAccessibility();
        }

        return Server().findMyCache.getAll();
    }

    static async refreshLocationsAccessibility() {
        await FileSystem.executeAppleScript(quitFindMyFriends());
        await waitMs(3000);

        // Make sure the Find My app is open.
        // Give it 5 seconds to open
        await FileSystem.executeAppleScript(startFindMyFriends());
        await waitMs(5000);

        // Bring the Find My app to the foreground so it refreshes the devices
        // Give it 15 seconods to refresh
        await FileSystem.executeAppleScript(showFindMyFriends());
        await waitMs(15000);

        // Re-hide the Find My App
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
