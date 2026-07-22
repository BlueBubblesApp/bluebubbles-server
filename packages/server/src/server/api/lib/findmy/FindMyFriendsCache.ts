import { isEmpty } from "@server/helpers/utils";
import { FindMyFriendLocation } from "./types";

export class FindMyFriendsCache {
    private locationsByHandle: Record<string, FindMyFriendLocation> = {};

    updateAll(friendLocations: FindMyFriendLocation[]): FindMyFriendLocation[] {
        const updatedLocations: FindMyFriendLocation[] = [];
        for (const friendLocation of friendLocations) {
            if (this.update(friendLocation)) {
                updatedLocations.push(friendLocation);
            }
        }

        return updatedLocations;
    }

    replaceAll(friendLocations: FindMyFriendLocation[]): FindMyFriendLocation[] {
        const snapshotHandles = new Set(
            friendLocations
                .map(friendLocation => friendLocation.handle)
                .filter((friendHandle): friendHandle is string => !isEmpty(friendHandle))
        );
        for (const cachedHandle of Object.keys(this.locationsByHandle)) {
            if (!snapshotHandles.has(cachedHandle)) {
                delete this.locationsByHandle[cachedHandle];
            }
        }

        return this.updateAll(friendLocations);
    }

    update(friendLocation: FindMyFriendLocation): boolean {
        const friendHandle = friendLocation?.handle;
        if (isEmpty(friendHandle)) return false;

        const storeLocation = (): true => {
            this.locationsByHandle[friendHandle] = friendLocation;
            return true;
        };

        const cachedLocation = this.locationsByHandle[friendHandle];
        if (!cachedLocation) return storeLocation();
        if (friendLocation.status === "legacy" && cachedLocation.status !== "legacy") return false;

        const cachedCoordinates = cachedLocation.coordinates ?? [0, 0];
        const updatedCoordinates = friendLocation.coordinates ?? [0, 0];
        const bothLocationsAreLegacy = cachedLocation.status === "legacy" && friendLocation.status === "legacy";
        const wouldReplaceKnownLegacyCoordinates =
            bothLocationsAreLegacy &&
            cachedCoordinates[0] !== 0 &&
            cachedCoordinates[1] !== 0 &&
            updatedCoordinates[0] === 0 &&
            updatedCoordinates[1] === 0;
        const updatedTimestamp = friendLocation.last_updated ?? 0;
        const cachedTimestamp = cachedLocation.last_updated ?? 0;
        const hasUnchangedLocation =
            cachedLocation.status === friendLocation.status &&
            cachedCoordinates[0] === updatedCoordinates[0] &&
            cachedCoordinates[1] === updatedCoordinates[1] &&
            updatedTimestamp === cachedTimestamp;
        const hasOlderTimestamp = updatedTimestamp < cachedTimestamp;

        if (wouldReplaceKnownLegacyCoordinates || hasUnchangedLocation || hasOlderTimestamp) return false;
        return storeLocation();
    }

    get(handle: string): FindMyFriendLocation | null {
        return this.locationsByHandle[handle] ?? null;
    }

    getAll(): FindMyFriendLocation[] {
        return Object.values(this.locationsByHandle);
    }
}
