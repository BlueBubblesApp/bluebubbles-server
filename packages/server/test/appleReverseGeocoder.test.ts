import assert from "node:assert/strict";
import test from "node:test";

import { FindMyAddressLabeler, type GeocodeBatch } from "../src/server/api/lib/findmy/AppleReverseGeocoder";
import { coordinateLabel } from "../src/server/api/lib/findmy/SecureLocationReader";
import { FindMyLocationItem } from "../src/server/api/lib/findmy/types";

// Mirrors SecureLocationReader: with no Apple label, the address is the coordinates.
const location = (overrides: Partial<FindMyLocationItem> = {}): FindMyLocationItem => {
    const coordinates = overrides.coordinates ?? [33.0198, -96.6989];
    const label = coordinateLabel(coordinates);
    return {
        handle: "friend@example.com",
        coordinates,
        long_address: label,
        short_address: label,
        subtitle: null,
        title: "Friend",
        last_updated: Date.UTC(2026, 9, 4, 7, 0, 0),
        is_locating_in_progress: false,
        status: "shallow",
        ...overrides
    };
};

const plano = { short: "Plano, TX", long: "1200 E Spring Creek Pkwy" };

test("labels missing addresses in one batch and reuses the coordinate-cell cache", async () => {
    const batches: Array<Array<[number, number]>> = [];
    const labeler = new FindMyAddressLabeler(async coordinates => {
        batches.push(coordinates);
        return coordinates.map(() => plano);
    });

    const [labeled, other] = await labeler.label([
        location(),
        location({ handle: "other@example.com", coordinates: [32.7767, -96.797] })
    ]);
    assert.equal(labeled.short_address, "Plano, TX");
    assert.equal(labeled.long_address, "1200 E Spring Creek Pkwy");
    assert.equal(other.short_address, "Plano, TX");
    assert.equal(batches.length, 1, "every unknown cell should share one helper call");
    assert.equal(batches[0].length, 2);

    // GPS jitter inside the same ~100 m cell is served from cache, without another call.
    const [jittered] = await labeler.label([location({ coordinates: [33.01981, -96.69891] })]);
    assert.equal(jittered.short_address, "Plano, TX");
    assert.equal(batches.length, 1);
    assert.equal(labeler.applyCached([location()])[0].short_address, "Plano, TX");
});

test("keeps real Apple labels and never geocodes unusable coordinates", async () => {
    let calls = 0;
    const labeler = new FindMyAddressLabeler(async coordinates => {
        calls += 1;
        return coordinates.map(() => plano);
    });

    const [home, noFix, invalid] = await labeler.label([
        location({ short_address: "Home", long_address: "Home" }),
        location({ handle: "no-fix", coordinates: [0, 0] }),
        location({ handle: "invalid", coordinates: [Number.NaN, -96] })
    ]);

    assert.equal(calls, 0);
    assert.equal(home.short_address, "Home");
    assert.equal(noFix.short_address, coordinateLabel([0, 0]));
    assert.equal(invalid.short_address, invalid.long_address);
});

test("does not carry a friend's old address to a new location", async () => {
    const labeler = new FindMyAddressLabeler(async coordinates =>
        coordinates.map(([latitude]) => (latitude > 34 ? undefined : plano))
    );

    await labeler.label([location()]);
    const [moved] = await labeler.label([location({ coordinates: [34.0522, -118.2437] })]);
    assert.equal(moved.short_address, "34.052° N, 118.244° W");
});

test("a failed or partial batch leaves items unlabelled and retries them later", async () => {
    let attempt = 0;
    const geocode: GeocodeBatch = async coordinates => {
        attempt += 1;
        if (attempt === 1) throw new Error("helper unavailable");
        return coordinates.map(() => plano);
    };
    const labeler = new FindMyAddressLabeler(geocode);

    const [failed] = await labeler.label([location()]);
    assert.equal(failed.short_address, "33.020° N, 96.699° W");

    const [retried] = await labeler.label([location()]);
    assert.equal(retried.short_address, "Plano, TX");
});

test("returns coordinate fallbacks at the deadline and exposes late labels", async () => {
    let release!: () => void;
    const gate = new Promise<void>(resolve => (release = resolve));
    const labeler = new FindMyAddressLabeler(async coordinates => {
        await gate;
        return coordinates.map(() => plano);
    });

    const result = await labeler.labelWithin([location()], 0);
    assert.equal(result.current[0].short_address, "33.020° N, 96.699° W");
    assert.ok(result.late);

    release();
    const late = await result.late;
    assert.equal(late?.[0].short_address, "Plano, TX");
});

test("overlapping refreshes run one batch at a time and share results", async () => {
    let release!: () => void;
    const gate = new Promise<void>(resolve => (release = resolve));
    let calls = 0;
    const labeler = new FindMyAddressLabeler(async coordinates => {
        calls += 1;
        await gate;
        return coordinates.map(() => plano);
    });

    const first = labeler.label([location()]);
    const second = labeler.label([location()]);
    release();

    const [[a], [b]] = await Promise.all([first, second]);
    assert.equal(a.short_address, "Plano, TX");
    assert.equal(b.short_address, "Plano, TX");
    assert.equal(calls, 1);
});
