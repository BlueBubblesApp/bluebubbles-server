import { strict as assert } from "node:assert";
import test from "node:test";

import { FindMyFriendsCache } from "../src/server/api/lib/findmy/FindMyFriendsCache";

const roster = {
    primaryHandles: new Map([["id-a", "+15550001"], ["id-b", "+15550002"]]),
    // Roster aliases are stored normalized (see normalizeFindMyHandle).
    aliases: new Map([["tel:15550001", "id-a"], ["tel:15550002", "id-b"]]),
    names: new Map([["id-a", "A"], ["id-b", "B"]]),
    favorites: new Map<string, number>()
};

const located = {
    handle: "+15550001",
    coordinates: [47.6, -122.3] as [number, number],
    long_address: null,
    short_address: null,
    subtitle: null,
    title: "A",
    last_updated: 1_700_000_000_000,
    is_locating_in_progress: false,
    status: "legacy" as const
};

test("a cache holding only roster placeholders reports no location, so startup still refreshes", () => {
    const cache = new FindMyFriendsCache(() => roster as any);
    cache.refreshRoster(true);
    assert.equal(cache.getAll().length, 2, "placeholders are listed");
    assert.equal(cache.hasAnyLocation(), false);
});

test("one real location is enough to skip the startup refresh", () => {
    const cache = new FindMyFriendsCache(() => roster as any);
    cache.refreshRoster(true);
    cache.addAll([located as any]);
    assert.equal(cache.hasAnyLocation(), true);
});

test("a [0, 0] coordinate with a timestamp is not treated as a location", () => {
    const cache = new FindMyFriendsCache(() => roster as any);
    cache.refreshRoster(true);
    cache.addAll([{ ...located, coordinates: [0, 0] } as any]);
    assert.equal(cache.hasAnyLocation(), false);
});
