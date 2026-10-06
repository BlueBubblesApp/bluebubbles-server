import { FindMyLocationItem } from "./types";

export class FindMyFriendsCache {
    cache: Record<string, FindMyLocationItem> = {};
    private readonly aliasToHandle: Record<string, string> = {};

    private static normalizeHandle(handle: string): string {
        return handle.trim().toLowerCase();
    }

    /**
     * Adds a list of location data to the cache.
     * Location data may be dropped if it doesn't update/change the cache at all.
     *
     * @param locationData
     * @returns The location data that was updated in the cache
     */
    addAll(locationData: FindMyLocationItem[]): FindMyLocationItem[] {
        const output: FindMyLocationItem[] = [];
        for (const i of locationData) {
            const success = this.add(i);
            if (success && i.handle) {
                output.push(this.get(i.handle) ?? i);
            }
        }

        return output;
    }

    /**
     * Adds a single location data to the cache
     *
     * @param locationData
     * @returns Whether the location data updated the cache at all
     */
    add(locationData: FindMyLocationItem): boolean {
        const suppliedHandle = locationData?.handle;
        if (!suppliedHandle) return false;

        const handles = [...new Set([suppliedHandle, ...(locationData.alternate_handles ?? [])].filter(Boolean))];
        const existingHandle = handles.find(handle => this.cache[handle]);
        const mappedHandle = handles
            .map(handle => this.aliasToHandle[FindMyFriendsCache.normalizeHandle(handle)])
            .find(handle => handle && this.cache[handle]);
        const handle = existingHandle ?? mappedHandle ?? suppliedHandle;
        for (const alias of handles) {
            this.aliasToHandle[FindMyFriendsCache.normalizeHandle(alias)] = handle;
        }

        // Alias metadata is internal to cache reconciliation and must not reach clients.
        const { alternate_handles: _, ...publicLocation } = locationData;
        const normalizedLocation: FindMyLocationItem = { ...publicLocation, handle };

        const updateCache = (): boolean => {
            this.cache[handle] = normalizedLocation;
            return true;
        };

        // If we don't have a cache item, add it to the cache as-is
        const currentData = this.cache[handle];
        if (!currentData) {
            return updateCache();
        }

        // If the update is a "legacy" update, and the current location isn't, ignore it.
        // We don't want to override a live/shallow location with a legacy one
        if (locationData?.status === "legacy" && currentData?.status !== "legacy") return false;

        // We don't want to overwrite a non [0, 0] location with a [0, 0] one.
        // We also don't need to update the cache if the metadata is the same.
        // Lastly, if the update timestamp is older than the current one, ignore it.
        const currentCoords = currentData?.coordinates ?? [0, 0];
        const updatedCoords = locationData?.coordinates ?? [0, 0];
        const noLocationType = currentData?.status === "legacy" && locationData?.status === "legacy";
        const updateTimestamp = locationData?.last_updated ?? 0;
        const currentTimestamp = currentData?.last_updated ?? 0;
        if (
            (
                noLocationType &&
                currentCoords[0] !== 0 &&
                currentCoords[1] !== 0 &&
                updatedCoords[0] === 0 &&
                updatedCoords[1] === 0
            ) ||
            (
                currentData?.status === locationData?.status &&
                currentCoords[0] === updatedCoords[0] &&
                currentCoords[1] === updatedCoords[1] &&
                updateTimestamp === currentTimestamp &&
                currentData?.short_address === locationData?.short_address &&
                currentData?.long_address === locationData?.long_address
            ) || (
                updateTimestamp < currentTimestamp
            )
        ) {
            return false;
        }

        return updateCache();
    }

    get(handle: string): FindMyLocationItem | null {
        const canonical = this.aliasToHandle[FindMyFriendsCache.normalizeHandle(handle)] ?? handle;
        return this.cache[canonical] ?? null;
    }

    getAll(): FindMyLocationItem[] {
        return Object.values(this.cache);
    }
}
