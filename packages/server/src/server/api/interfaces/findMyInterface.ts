import { Server } from "@server";
import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur, isMinSonoma14_4 } from "@server/env";
import { checkPrivateApiStatus, waitMs } from "@server/helpers/utils";
import { quitFindMyFriends, startFindMyFriends, showFindMyFriends, hideFindMyFriends } from "../apple/scripts";
import { FindMyDevice, FindMyItem, FindMyLocationItem } from "@server/api/lib/findmy/types";
import { transformFindMyItemToDevice } from "@server/api/lib/findmy/utils";
import { FindMyKeyManager } from "@server/api/lib/findmy/FindMyKeyManager";
import { decryptCacheBuffer } from "@server/api/lib/findmy/decrypt/cache";
import { readFriendLocations, RawFriendLocation } from "@server/api/lib/findmy/decrypt/localStorageReader";
import { readFmfContacts } from "@server/api/lib/findmy/decrypt/fmfReader";

export class FindMyInterface {
    static async getFriends() {
        return Server().findMyCache.getAll();
    }

    static async getDevices(): Promise<Array<FindMyDevice> | null> {
        try {
            const [devices, items] = await Promise.all([
                FindMyInterface.readDataFile("Devices"),
                FindMyInterface.readDataFile("Items")
            ]);

            // Return null if neither of the files exist
            if (devices == null && items == null) return null;

            // Get any items with a group identifier
            const itemsWithGroup = (items ?? []).filter(item => item.groupIdentifier);
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
        // Can't use the Private API to refresh devices yet
        await this.refreshLocationsAccessibility();
        return await this.getDevices();
    }

    static async refreshFriends(openFindMyApp = true): Promise<FindMyLocationItem[]> {
        // macOS 14.4+ : the Private API hook no longer works and the cache is encrypted.
        // Read & decrypt the LocalStorage.db cache directly (requires imported keys).
        if (isMinSonoma14_4) {
            try {
                const locations = await FindMyInterface.readFriendsFromCache();
                if (locations.length > 0) {
                    Server().findMyCache.addAll(locations);
                }
            } catch (ex: any) {
                Server().logger.debug("Failed to read FindMy friends from decrypted cache.");
                Server().logger.debug(String(ex));
            }

            return Server().findMyCache.getAll();
        }

        // Legacy path (macOS 11.0 - 13.x): use the Private API injection
        const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        if (papiEnabled && isMinBigSur) {
            checkPrivateApiStatus();
            const result = await Server().privateApi.findmy.refreshFriends();
            const refreshLocations = result?.data?.locations ?? [];

            // Save the data to the cache; the cache handles de-duping/updating.
            Server().findMyCache.addAll(refreshLocations);

            // Open the Find My app to trigger background location updates.
            if (openFindMyApp) {
                this.refreshLocationsAccessibility();
            }
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

    /**
     * Reads friend locations by decrypting LocalStorage.db (coordinates) and joining
     * with the FMF cache (display names). Returns items in the legacy API shape.
     */
    static async readFriendsFromCache(): Promise<FindMyLocationItem[]> {
        const localStorageKey = FindMyKeyManager.loadLocalStorageKey();
        if (!localStorageKey) {
            Server().logger.debug("FindMy LocalStorage key not imported — cannot read friend locations.");
            return [];
        }

        if (!fs.existsSync(FileSystem.findMyLocalStorageDbPath)) {
            Server().logger.debug(`FindMy LocalStorage.db not found at ${FileSystem.findMyLocalStorageDbPath}`);
            return [];
        }

        const rawLocations = readFriendLocations(localStorageKey);

        // Best-effort: pull friend display names from the FMF cache
        let names: Record<string, string> = {};
        const fmfKey = await FindMyKeyManager.loadCacheKey("FMF");
        if (fmfKey) {
            try {
                names = await readFmfContacts(fmfKey);
            } catch (ex: any) {
                Server().logger.debug(`Failed to read FMF contacts: ${String(ex)}`);
            }
        }

        return rawLocations.map(raw => FindMyInterface.buildFriendLocationItem(raw, names));
    }

    private static buildFriendLocationItem(
        raw: RawFriendLocation,
        names: Record<string, string>
    ): FindMyLocationItem {
        const loc = raw.location ?? {};

        const lat = typeof loc.latitude === "number" ? loc.latitude : 0;
        const lng = typeof loc.longitude === "number" ? loc.longitude : 0;

        // timestamp may be a plist Date, seconds, or ms — normalize to ms
        let lastUpdated = 0;
        if (loc.timestamp instanceof Date) {
            lastUpdated = loc.timestamp.getTime();
        } else if (typeof loc.timestamp === "number") {
            lastUpdated = loc.timestamp > 1e12 ? loc.timestamp : Math.round(loc.timestamp * 1000);
        }

        const name = names[raw.findMyId] ?? null;
        const handle = raw.handle ?? null;
        const title = name ?? handle ?? raw.findMyId;
        const hasCoords = lat !== 0 || lng !== 0;

        // NOTE: Address text (long/short/subtitle) is NOT persisted in the friend cache —
        // `secureLocations.value` only holds coordinates. The Find My app reverse-geocodes
        // addresses at display time. We leave these null; clients can geocode coordinates.
        return {
            handle,
            coordinates: [lat, lng],
            long_address: null,
            short_address: null,
            subtitle: null,
            title,
            last_updated: lastUpdated,
            is_locating_in_progress: 0,
            status: hasCoords ? "live" : "shallow"
        };
    }

    static async readItemGroups(): Promise<Array<any>> {
        const itemGroupsPath = path.join(FileSystem.findMyDir, "ItemGroups.data");
        if (!fs.existsSync(itemGroupsPath)) return [];

        const parsed = await FindMyInterface.readCacheArray(itemGroupsPath);
        return parsed ?? [];
    }

    /**
     * Reads a Find My FMIP cache `.data` file as an array, transparently handling both
     * the legacy plaintext-JSON format and the macOS 14.4+ ChaCha20-Poly1305 format.
     */
    private static async readDataFile<T extends "Devices" | "Items">(
        type: T
    ): Promise<Array<T extends "Devices" ? FindMyDevice : FindMyItem> | null> {
        const dataPath = path.join(FileSystem.findMyDir, `${type}.data`);
        return (await FindMyInterface.readCacheArray(dataPath)) as any;
    }

    private static async readCacheArray(filePath: string): Promise<Array<any> | null> {
        if (!fs.existsSync(filePath)) return null;

        const buffer = fs.readFileSync(filePath);

        // macOS 14.4+: encrypted FMIP cache (binary plist wrapper with `encryptedData`)
        const fmipKey = await FindMyKeyManager.loadCacheKey("FMIP");
        if (fmipKey) {
            try {
                const decrypted = await decryptCacheBuffer(buffer, fmipKey);
                const arr = FindMyInterface.coerceArray(decrypted);
                if (arr) return arr;
            } catch (ex: any) {
                Server().logger.debug(`Failed to decrypt FindMy cache file ${filePath}: ${String(ex)}`);
            }
        }

        // Legacy plaintext JSON (pre-14.4)
        try {
            const parsed = JSON.parse(buffer.toString("utf-8"));
            if (Array.isArray(parsed)) return parsed;
        } catch {
            // not plaintext JSON
        }

        return null;
    }

    /** Coerces a decrypted plist payload into an array of records, if possible. */
    private static coerceArray(decrypted: any): Array<any> | null {
        if (decrypted == null) return null;
        if (Array.isArray(decrypted)) return decrypted;

        // Some payloads wrap the list in a single container key
        if (typeof decrypted === "object") {
            const arrayValue = Object.values(decrypted).find(v => Array.isArray(v));
            if (arrayValue) return arrayValue as Array<any>;
        }

        return null;
    }
}
