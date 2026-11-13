import { isEmpty } from "@server/helpers/utils";
import { FindMyLocationItem } from "./types";
import { Server } from "@server";

export class FindMyFriendsCache {
    cache: Record<string, FindMyLocationItem> = {};

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
            if (success) {
                output.push(i);
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
        const handle = locationData?.handle;
        if (isEmpty(handle)) return false;

        const updateCache = (): boolean => {
            this.cache[handle] = locationData;
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
                updateTimestamp === currentTimestamp
            ) || (
                updateTimestamp < currentTimestamp
            )
        ) {
            return false;
        }

        return updateCache();
    }

    get(handle: string): FindMyLocationItem | null {
        return this.cache[handle] ?? null;
    }

    getAll(): FindMyLocationItem[] {
        return Object.values(this.cache);
    }
}
