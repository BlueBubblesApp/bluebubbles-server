import assert from "node:assert/strict";
import test from "node:test";

import { FindMyFriendsCache } from "../src/server/api/lib/findmy/FindMyFriendsCache";
import { FindMyLocationItem } from "../src/server/api/lib/findmy/types";
import { buildFindMyRoster, FindMyRoster } from "../src/server/api/lib/findmy/FindMyFriendRoster";

const location = (handle: string, overrides: Partial<FindMyLocationItem> = {}): FindMyLocationItem => ({
    handle,
    coordinates: [33.0198, -96.6989],
    long_address: "Plano, TX",
    short_address: "Plano, TX",
    subtitle: null,
    title: "Synthetic Friend",
    last_updated: 1,
    is_locating_in_progress: false,
    status: "shallow",
    ...overrides
});

test("direct-reader aliases reuse an existing Messages handle in emitted updates", () => {
    const cache = new FindMyFriendsCache();
    cache.add(location("friend@example.com", { status: "legacy" }));

    const added = cache.addAll([
        location("+15550123", {
            alternate_handles: ["friend@example.com"],
            last_updated: 2
        })
    ]);

    assert.equal(cache.getAll().length, 1);
    assert.equal(added.length, 1);
    assert.equal(added[0].handle, "friend@example.com");
    assert.equal(added[0].alternate_handles, undefined);
});

test("accepted phone and email aliases resolve to one cached friend", () => {
    const cache = new FindMyFriendsCache();
    const phone = "+15550123";

    const added = cache.addAll([location(phone, { alternate_handles: ["friend@example.com"] })]);
    assert.equal(added[0].alternate_handles, undefined);
    const updated = cache.addAll([location("friend@example.com", { last_updated: 2 })]);

    const friends = cache.getAll();
    assert.equal(friends.length, 1);
    assert.equal(friends[0].handle, phone);
    assert.equal(friends[0].alternate_handles, undefined);
    assert.equal(updated.length, 1);
    assert.equal(updated[0].handle, phone);
    assert.equal(updated[0].alternate_handles, undefined);
});


const rosterFor = (ids: string[]): FindMyRoster =>
    buildFindMyRoster({
        myInfo: { emails: ["owner@example.com"] },
        contacts: Object.fromEntries(ids.map(id => [id, { displayName: id === "friend-1" ? "Current Name" : id }])),
        following: ids.map(id => ({
            id,
            invitationAcceptedHandles: [id === "friend-1" ? "current@example.com" : `${id}@example.com`],
            invitationFromHandles: ["owner@example.com"]
        })),
        followers: ids.map(id => ({
            id,
            invitationAcceptedHandles: ["owner@example.com"],
            invitationFromHandles: [id === "friend-1" ? "old@example.edu" : `${id}@example.com`]
        })),
        preferences: { favorites: [{ id: "friend-1", order: 0 }] }
    })!;

test("authoritative roster collapses old and current handles to one friend", () => {
    const cache = new FindMyFriendsCache(() => rosterFor(["friend-1"]));
    cache.refreshRoster(true);

    cache.add(location("old@example.edu", { title: "Old label", last_updated: 1, status: "legacy" }));
    cache.add(location("current@example.com", { title: "Incoming label", last_updated: 2 }));

    assert.deepEqual(cache.getAll(), [
        {
            ...location("current@example.com", { title: "Current Name", last_updated: 2 }),
            favorite_order: 0
        }
    ]);
    assert.equal(cache.get("old@example.edu")?.handle, "current@example.com");
});

test("authoritative roster rejects updates for people Apple no longer lists", () => {
    const cache = new FindMyFriendsCache(() => rosterFor(["friend-1"]));
    cache.refreshRoster(true);

    assert.deepEqual(cache.addAll([location("removed@example.com")]), []);
    assert.equal(cache.get("removed@example.com"), null);
    assert.deepEqual(cache.getAll().map(item => item.handle), ["current@example.com"]);
});

test("refreshing the authoritative roster removes people who stopped sharing", () => {
    let roster = rosterFor(["friend-1", "friend-2"]);
    const cache = new FindMyFriendsCache(() => roster);
    cache.refreshRoster(true);
    cache.add(location("current@example.com"));
    cache.add(location("friend-2@example.com"));
    assert.equal(cache.getAll().length, 2);

    roster = rosterFor(["friend-1"]);
    cache.refreshRoster(true);

    assert.equal(cache.getAll().length, 1);
    assert.equal(cache.getAll()[0].handle, "current@example.com");
});


test("authoritative roster keeps friends who currently have no location", () => {
    const cache = new FindMyFriendsCache(() => rosterFor(["friend-1", "friend-2"]));
    cache.refreshRoster(true);
    cache.add(location("current@example.com", { last_updated: 2 }));

    const missing = cache.getAll().find(item => item.handle === "friend-2@example.com");
    assert.equal(cache.getAll().length, 2);
    assert.deepEqual(missing?.coordinates, [0, 0]);
    assert.equal(missing?.status, "legacy");
    assert.equal(missing?.title, "friend-2");
});
