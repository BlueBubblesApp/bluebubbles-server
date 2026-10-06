import assert from "node:assert/strict";
import test from "node:test";

import { FindMyFriendsCache } from "../src/server/api/lib/findmy/FindMyFriendsCache";
import { FindMyLocationItem } from "../src/server/api/lib/findmy/types";

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
