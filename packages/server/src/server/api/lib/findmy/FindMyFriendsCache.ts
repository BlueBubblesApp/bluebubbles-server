import { FindMyRoster, normalizeFindMyHandle } from "./FindMyFriendRoster";
import { FindMyLocationItem } from "./types";

const ROSTER_RELOAD_MS = 30 * 1000;

export class FindMyFriendsCache {
    cache: Record<string, FindMyLocationItem> = {};
    private readonly aliasToHandle: Record<string, string> = {};
    private roster: FindMyRoster | null = null;
    private rosterLoadedAt = Number.NEGATIVE_INFINITY;

    constructor(private readonly loadRoster: () => FindMyRoster | null = () => null) {}

    private static normalizeHandle(handle: string): string {
        return handle.trim().toLowerCase();
    }

    /** Re-reads Apple's friend list and removes cached rows Apple no longer lists. */
    refreshRoster(force = false, now = Date.now()): void {
        if (!force && now - this.rosterLoadedAt < ROSTER_RELOAD_MS) return;
        this.rosterLoadedAt = now;
        const roster = this.loadRoster();
        if (!roster) return;

        const previous = Object.values(this.cache);
        this.roster = roster;
        this.cache = {};
        for (const item of previous) this.add(item, false);
    }

    private rosterIdFor(handles: string[]): string | undefined {
        if (!this.roster) return undefined;
        for (const handle of handles) {
            const id = this.roster.aliases.get(normalizeFindMyHandle(handle));
            if (id) return id;
        }
        return undefined;
    }

    private publicItem(key: string, item: FindMyLocationItem): FindMyLocationItem {
        const favoriteOrder = this.roster?.favorites.get(key);
        return favoriteOrder === undefined ? item : { ...item, favorite_order: favoriteOrder };
    }

    addAll(locationData: FindMyLocationItem[]): FindMyLocationItem[] {
        const output: FindMyLocationItem[] = [];
        for (const item of locationData) {
            const success = this.add(item);
            if (success && item.handle) output.push(this.get(item.handle) ?? item);
        }
        return output;
    }

    add(locationData: FindMyLocationItem, reloadRoster = true): boolean {
        const suppliedHandle = locationData?.handle;
        if (!suppliedHandle) return false;
        const handles = [...new Set([suppliedHandle, ...(locationData.alternate_handles ?? [])].filter(Boolean))];

        if (this.roster) {
            let rosterId = this.rosterIdFor(handles);
            if (!rosterId && reloadRoster) {
                this.refreshRoster();
                rosterId = this.rosterIdFor(handles);
            }
            // Find My no longer lists this person, so do not resurrect a stale helper row.
            if (!rosterId) return false;

            const { alternate_handles: _, favorite_order: __, ...publicLocation } = locationData;
            return this.store(rosterId, {
                ...publicLocation,
                handle: this.roster.primaryHandles.get(rosterId) ?? suppliedHandle,
                title: this.roster.names.get(rosterId) ?? locationData.title
            });
        }

        // Compatibility fallback when Apple's roster file is unavailable.
        const existingHandle = handles.find(handle => this.cache[handle]);
        const mappedHandle = handles
            .map(handle => this.aliasToHandle[FindMyFriendsCache.normalizeHandle(handle)])
            .find(handle => handle && this.cache[handle]);
        const handle = existingHandle ?? mappedHandle ?? suppliedHandle;
        for (const alias of handles) this.aliasToHandle[FindMyFriendsCache.normalizeHandle(alias)] = handle;
        const { alternate_handles: _, ...publicLocation } = locationData;
        return this.store(handle, { ...publicLocation, handle });
    }

    private store(key: string, locationData: FindMyLocationItem): boolean {
        const currentData = this.cache[key];
        const updateCache = (): boolean => {
            this.cache[key] = locationData;
            return true;
        };
        if (!currentData) return updateCache();

        if (locationData.status === "legacy" && currentData.status !== "legacy") return false;

        const currentCoords = currentData.coordinates ?? [0, 0];
        const updatedCoords = locationData.coordinates ?? [0, 0];
        const noLocationType = currentData.status === "legacy" && locationData.status === "legacy";
        const updateTimestamp = locationData.last_updated ?? 0;
        const currentTimestamp = currentData.last_updated ?? 0;
        if (
            (noLocationType &&
                currentCoords[0] !== 0 &&
                currentCoords[1] !== 0 &&
                updatedCoords[0] === 0 &&
                updatedCoords[1] === 0) ||
            (currentData.status === locationData.status &&
                currentCoords[0] === updatedCoords[0] &&
                currentCoords[1] === updatedCoords[1] &&
                updateTimestamp === currentTimestamp &&
                currentData.short_address === locationData.short_address &&
                currentData.long_address === locationData.long_address) ||
            updateTimestamp < currentTimestamp
        ) {
            return false;
        }
        return updateCache();
    }

    get(handle: string): FindMyLocationItem | null {
        const rosterId = this.rosterIdFor([handle]);
        const key = rosterId ?? this.aliasToHandle[FindMyFriendsCache.normalizeHandle(handle)] ?? handle;
        const item = this.cache[key];
        return item ? this.publicItem(key, item) : null;
    }

    getAll(): FindMyLocationItem[] {
        return Object.entries(this.cache).map(([key, item]) => this.publicItem(key, item));
    }
}
