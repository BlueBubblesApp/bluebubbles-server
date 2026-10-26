import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
    assertFindMyLocationsFresh,
    assertFindMyLocationsUsable,
    decryptSecureLocationRecord,
    loadBeaconStoreKey,
    coordinateLabel,
    locationLabelForDisplay,
    readFindMyFriendsFromSecureCache,
    supportsSecureLocationCacheReader
} from "../src/server/api/lib/findmy/SecureLocationReader";

const KEY = Buffer.from("11".repeat(32), "hex");
const WRONG_KEY = Buffer.from("22".repeat(32), "hex");

test("uses SecureLocationCache only before Sonoma", () => {
    assert.equal(supportsSecureLocationCacheReader(false), true);
    assert.equal(supportsSecureLocationCacheReader(true), false);
});

test("normalizes Apple's missing-label sentinel without discarding real labels", () => {
    assert.equal(locationLabelForDisplay("Home"), "Home");
    assert.equal(locationLabelForDisplay("  Work  "), "Work");
    assert.equal(locationLabelForDisplay("$null"), null);
    assert.equal(locationLabelForDisplay(undefined), null);
    assert.equal(coordinateLabel([33.0198, -96.6989]), "33.020° N, 96.699° W");
    assert.equal(coordinateLabel([-33.8688, 151.2093]), "33.869° S, 151.209° E");
});
const ENCRYPTED_RECORD = Buffer.from(
    "YnBsaXN0MDCjAQIDTxAQIiIiIiIiIiIiIiIiIiIiIk8QEEbo1aRZoCw/Suzxy0bXbdVPEP5+w31G7ZOvguHw5DTLdlRAYrMbzEs2V+fkWuthi+MSV7Wl3XkStVjFByX8tGw0a/LQg7fTlckSXZeXMAllS6YL3S69b1SHlZbjLAvkzIpSXQwkZB7obrMMhFTMQCR2NXSq6/2UN1ccWFmZ8Pg7pIteAijRJ4PSdtgUWjfaxiXDap5IS1q9koodaW3gShPjL5/aHlUEZO7DF8YEFSTq7VYAYU76pH1ZYuN0xBxgiEOm2N97Z5/RPj5Oot+aNcqXsqyylZkPLFTFiMUwouiiYkkUOJERGUMXnWeCoSb2o46YHvP1MZGzlDo21BbO1ICdVrFixwXlyx6eKupbUchiAgAIAAwAHwAyAAAAAAAAAgEAAAAAAAAABAAAAAAAAAAAAAAAAAAAATM=",
    "base64"
);

// Same dummy key and timestamp, but zeroed coordinates. A fully-zero record and a
// half-zero record are both needed: a fully-zero one alone cannot distinguish the
// `latitude !== 0 || longitude !== 0` test from `&&`.
const ZERO_RECORD = Buffer.from(
    "YnBsaXN0MDCjAQIDTxAQQkJCQkJCQkJCQkJCQkJCQk8QEL5197TEvUB/vmp9MVvOT9hPENk7KJM0LnlTShSSLc2QDb1LeRTk5AgnmkY1ASuv3vgkhkAh7U97EXHdlCHefZowP6XyfYFhcbSvHpNGBfTqtPoOminjvYNFPiu46Hu5kbPG6vuQvlpmdGMXo1PXgdlovnqMMOT7u1RBXtY6kU9aichupKfykv/FC7HNcJ558FqriQWj3iXxSUPcdoI/RhPHU1FXSW1/H9J8yQKe9sdA31FTCnEu1qa0MOv1oV0RJORY23URenRm8/xcRe1qb2EALR48FTYJAQ8ohRi5XIMMdgHAawp16M2nhJe9AAgADAAfADIAAAAAAAACAQAAAAAAAAAEAAAAAAAAAAAAAAAAAAABDg==",
    "base64"
);
const HALF_ZERO_RECORD = Buffer.from(
    "YnBsaXN0MDCjAQIDTxAQQkJCQkJCQkJCQkJCQkJCQk8QEKohBOHD8FOm9gH6mZOI3YRPEOM7KJM0LnlTShSSLc2QDb1LeRTk5AgnmkY1ASuv3vgkhkAh7U97EXHdlCHefZowP6XyfZNlb72vHpNGBfTqtPoPmSnjvYNFPiu46Hu5kbPG6vuQvlpmdGMXo1PXgdlovnqMMOT7u1RBXtY6kU9aichupKfykv/FC7HNcJ558FqriQWj3iXxSUPcdoI/RhPHU1JXSW1/H9J8yQKe9sdA31FTCnE+VzkeZhwTbGgqaDv8W6aN7agcgnTi0awgMAlyUY+kt50JAQ8ohRa4XYMMdgHAawp66M2nhJcWEYuTPjV9+f3spQAIAAwAHwAyAAAAAAAAAgEAAAAAAAAABAAAAAAAAAAAAAAAAAAAARg=",
    "base64"
);

const writeFriendCache = (friendsPath: string) =>
    fs.writeFileSync(
        friendsPath,
        JSON.stringify({
            contacts: {},
            following: [
                { id: "synthetic-id-0001", invitationAcceptedHandles: ["one@example.com"] },
                { id: "synthetic-id-0002", invitationAcceptedHandles: ["two@example.com"] }
            ]
        })
    );

test("decrypts an authenticated SecureLocationCache record", () => {
    const result = decryptSecureLocationRecord(ENCRYPTED_RECORD, KEY);

    assert.equal(result.identifier, "synthetic-record");
    assert.equal(result.secureLocation.latitude, 33.123456);
    assert.equal(result.secureLocation.longitude, -96.654321);
    assert.equal(result.secureLocation.horizontalAccuracy, 7.5);
    assert.equal(result.secureLocation.findMyId, "synthetic-id-0001");
    assert.equal(result.secureLocation.timestamp.getTime(), Date.UTC(2026, 0, 2, 3, 4, 5, 678));
});

test("invokes /usr/bin/security with an argument array, not a shell string", () => {
    const calls: Array<{ file: string; args: readonly string[] }> = [];
    const exec = (file: string, args: readonly string[]) => {
        calls.push({ file, args });
        return `${"11".repeat(32)}\n`;
    };

    assert.deepEqual(loadBeaconStoreKey(exec), KEY);
    assert.deepEqual(calls, [
        {
            file: "/usr/bin/security",
            args: ["find-generic-password", "-s", "BeaconStore", "-a", "BeaconStoreKey", "-w"]
        }
    ]);
});

test("rejects a keychain value that is not exactly 32 hex bytes", () => {
    for (const bad of ["", "not-hex", "11".repeat(31), "11".repeat(33), `${"11".repeat(32)}zz`]) {
        assert.throws(() => loadBeaconStoreKey(() => bad), /exactly 32 hex-encoded bytes/);
    }
});

test("never lets the keychain secret ride on a thrown error", () => {
    const secret = "aa".repeat(32);
    // execFileSync attaches captured stdout to the error it throws, so `security` can
    // fail (status 36 over SSH) while the key still sits on error.stdout/.output.
    const exec = () => {
        const ex: any = new Error("Command failed: /usr/bin/security find-generic-password");
        ex.status = 36;
        ex.stdout = secret;
        ex.output = [null, secret, ""];
        throw ex;
    };

    let caught: any;
    try {
        loadBeaconStoreKey(exec);
    } catch (ex) {
        caught = ex;
    }

    assert.ok(caught, "expected loadBeaconStoreKey to throw");
    const serialized = `${String(caught)}${JSON.stringify(caught, Object.getOwnPropertyNames(caught))}`;
    assert.equal(serialized.includes(secret), false);
    assert.match(caught.message, /status 36/);
});

test("reads encrypted records and joins them to Find My contact names", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "secure-location-reader-"));
    const cacheDir = path.join(root, "SecureLocationCache");
    const friendsPath = path.join(root, "FriendCacheData.data");
    fs.mkdirSync(cacheDir);
    fs.writeFileSync(path.join(cacheDir, "synthetic.record"), ENCRYPTED_RECORD);
    fs.writeFileSync(path.join(cacheDir, "corrupt.record"), Buffer.from("partially written record"));
    fs.writeFileSync(path.join(cacheDir, "._synthetic.record"), Buffer.from("AppleDouble metadata"));
    fs.writeFileSync(
        friendsPath,
        JSON.stringify({
            contacts: {
                "synthetic-id-0001": {
                    displayName: "Synthetic Friend",
                    shortName: "Synthetic"
                }
            },
            following: [{ id: "synthetic-id-0001", invitationAcceptedHandles: ["synthetic@example.com"] }]
        })
    );

    try {
        const failures: string[] = [];
        assert.deepEqual(
            readFindMyFriendsFromSecureCache(cacheDir, friendsPath, KEY, name => failures.push(name)),
            [
                {
                    handle: "synthetic@example.com",
                    coordinates: [33.123456, -96.654321],
                    long_address: "Home",
                    short_address: "Home",
                    subtitle: null,
                    title: "Synthetic Friend",
                    last_updated: Date.UTC(2026, 0, 2, 3, 4, 5, 678),
                    is_locating_in_progress: false,
                    status: "shallow"
                }
            ]
        );
        assert.deepEqual(failures, ["corrupt.record"]);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test("rejects a refresh when every direct location is stale", () => {
    const now = Date.UTC(2026, 0, 2, 3, 10, 0);
    const locations = [
        {
            handle: "synthetic-id-0001",
            coordinates: [33.123456, -96.654321] as [number, number],
            long_address: null,
            short_address: null,
            subtitle: null,
            title: "Synthetic Friend",
            last_updated: Date.UTC(2026, 0, 2, 3, 4, 5),
            is_locating_in_progress: false,
            status: "live" as const
        }
    ];

    assert.throws(() => assertFindMyLocationsFresh(locations, now, 5 * 60 * 1000), /newest location is 355000ms old/);
});

test("treats an unparseable timestamp as stale instead of passing the freshness check", () => {
    const now = Date.UTC(2026, 0, 2, 3, 10, 0);
    const base = {
        coordinates: [33.123456, -96.654321] as [number, number],
        long_address: null,
        short_address: null,
        subtitle: null,
        title: "Synthetic Friend",
        is_locating_in_progress: false,
        status: "live" as const
    };

    // A record whose timestamp did not parse yields NaN. Math.max(...) over any NaN
    // returns NaN, and every comparison against NaN is false, so a naive age check
    // silently reports hours-old data as fresh.
    assert.throws(
        () =>
            assertFindMyLocationsFresh(
                [
                    { ...base, handle: "stale-friend", last_updated: Date.UTC(2026, 0, 2, 2, 0, 0) },
                    { ...base, handle: "unparseable-friend", last_updated: Number.NaN }
                ],
                now,
                5 * 60 * 1000
            ),
        /stale/i
    );
});

test("serves stale-but-valid locations: usability does not depend on age", () => {
    const now = Date.UTC(2026, 0, 2, 3, 10, 0);
    const base = {
        coordinates: [33.123456, -96.654321] as [number, number],
        long_address: null,
        short_address: null,
        subtitle: null,
        title: "Synthetic Friend",
        is_locating_in_progress: false,
        status: "live" as const
    };

    // 34 minutes old: far past the 5-minute refresh threshold. The serving path must
    // still return it. Rejecting it here is what surfaced "Something went wrong" on
    // the client, because a cold request falls through to the Messages/FMFSessions
    // path that has no on-demand refresh on Monterey.
    const stale = [{ ...base, handle: "stale-friend", last_updated: Date.UTC(2026, 0, 2, 2, 36, 0) }];

    assert.throws(() => assertFindMyLocationsFresh(stale, now, 5 * 60 * 1000), /stale/i);
    assert.doesNotThrow(() => assertFindMyLocationsUsable(stale));
});

test("rejects structurally unusable locations regardless of age", () => {
    const base = {
        long_address: null,
        short_address: null,
        subtitle: null,
        title: "Synthetic Friend",
        last_updated: Date.now(),
        is_locating_in_progress: false,
        status: "live" as const
    };

    assert.throws(() => assertFindMyLocationsUsable([]), /no friend locations/i);

    // A (0, 0) coordinate means "no fix", not a position off the Gulf of Guinea.
    assert.throws(
        () => assertFindMyLocationsUsable([{ ...base, handle: "no-fix", coordinates: [0, 0] as [number, number] }]),
        /usable/i
    );

    // NaN survives `typeof x === "number"` and JSON.stringify renders it as null,
    // so the client would receive coordinates: [null, null].
    assert.throws(
        () =>
            assertFindMyLocationsUsable([
                { ...base, handle: "nan-coords", coordinates: [Number.NaN, Number.NaN] as [number, number] }
            ]),
        /usable/i
    );
});

test("keys locations by the friend's real handle so they merge with the Messages path", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "secure-location-handle-"));
    const cacheDir = path.join(root, "SecureLocationCache");
    const friendsPath = path.join(root, "FriendCacheData.data");
    fs.mkdirSync(cacheDir);
    fs.writeFileSync(path.join(cacheDir, "synthetic.record"), ENCRYPTED_RECORD);

    // Mirrors the live FriendCacheData.data layout on macOS 12.7.6: `contacts` is keyed
    // by Apple's opaque friend id (29/29 match `following[].id`), and the only real
    // phone/email handles live in `following[].invitationAcceptedHandles`.
    fs.writeFileSync(
        friendsPath,
        JSON.stringify({
            contacts: {
                "synthetic-id-0001": { displayName: "Synthetic Friend", shortName: "Synthetic" }
            },
            following: [
                {
                    id: "synthetic-id-0001",
                    invitationAcceptedHandles: ["+155****0123", "synthetic@example.com"]
                }
            ]
        })
    );

    try {
        const [location] = readFindMyFriendsFromSecureCache(cacheDir, friendsPath, KEY);
        assert.equal(location.handle, "+155****0123");
        assert.deepEqual(location.alternate_handles, ["synthetic@example.com"]);
        assert.equal(location.title, "Synthetic Friend");
        assert.equal(location.short_address, "Home");
        assert.equal(location.long_address, "Home");
        assert.equal(location.status, "shallow");
        // The client reads is_locating_in_progress as a Dart bool. Emitting an int
        // (the old `0`) serializes as JSON `0` and throws a TypeError in FindMyFriend.fromJson.
        assert.equal(location.is_locating_in_progress, false);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test("skips a non-regular file instead of blocking forever on it", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "secure-location-irregular-"));
    const cacheDir = path.join(root, "SecureLocationCache");
    const friendsPath = path.join(root, "FriendCacheData.data");
    fs.mkdirSync(cacheDir);
    fs.writeFileSync(path.join(cacheDir, "good.record"), ENCRYPTED_RECORD);
    writeFriendCache(friendsPath);

    // readdirSync + endsWith(".record") does not prove the entry is a regular file.
    // readFileSync on a character device such as /dev/zero never returns, which would
    // wedge the Electron main thread past any try/catch.
    fs.symlinkSync("/dev/zero", path.join(cacheDir, "zero.record"));

    try {
        const locations = readFindMyFriendsFromSecureCache(cacheDir, friendsPath, KEY);
        assert.equal(locations.length, 1);
        assert.equal(locations[0].coordinates[0], 33.123456);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test("surfaces a batch-wide decryption failure rather than reporting no friends", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "secure-location-wrongkey-"));
    const cacheDir = path.join(root, "SecureLocationCache");
    const friendsPath = path.join(root, "FriendCacheData.data");
    fs.mkdirSync(cacheDir);
    fs.writeFileSync(path.join(cacheDir, "a.record"), ENCRYPTED_RECORD);
    fs.writeFileSync(path.join(cacheDir, "b.record"), ENCRYPTED_RECORD);
    writeFriendCache(friendsPath);

    try {
        const failures: string[] = [];
        // A rotated or re-keyed BeaconStore must not look like "this user has no friends".
        assert.throws(
            () => readFindMyFriendsFromSecureCache(cacheDir, friendsPath, WRONG_KEY, name => failures.push(name)),
            /Failed to decrypt all 2 SecureLocationCache records/
        );
        assert.deepEqual(failures, ["a.record", "b.record"]);

        // An empty directory legitimately yields an empty list.
        fs.rmSync(path.join(cacheDir, "a.record"));
        fs.rmSync(path.join(cacheDir, "b.record"));
        assert.deepEqual(readFindMyFriendsFromSecureCache(cacheDir, friendsPath, WRONG_KEY), []);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test("drops zero-coordinate records so they cannot overwrite a known location", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "secure-location-zero-"));
    const cacheDir = path.join(root, "SecureLocationCache");
    const friendsPath = path.join(root, "FriendCacheData.data");
    fs.mkdirSync(cacheDir);
    fs.writeFileSync(path.join(cacheDir, "zero.record"), ZERO_RECORD);
    fs.writeFileSync(path.join(cacheDir, "half.record"), HALF_ZERO_RECORD);
    writeFriendCache(friendsPath);

    try {
        // FindMyFriendsCache.add only blocks (0,0) clobbering when both sides are
        // "legacy", so a fresh (0,0) would replace a real location and be emitted as
        // a live update. A half-zero coordinate is a real place and must survive.
        const locations = readFindMyFriendsFromSecureCache(cacheDir, friendsPath, KEY);
        assert.deepEqual(
            locations.map(location => location.handle),
            ["two@example.com"]
        );
        assert.deepEqual(locations[0].coordinates, [0, -96.654321]);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test("skips records it cannot match to a real handle instead of publishing Apple's opaque id", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "secure-location-badjson-"));
    const cacheDir = path.join(root, "SecureLocationCache");
    const friendsPath = path.join(root, "FriendCacheData.data");
    fs.mkdirSync(cacheDir);
    fs.writeFileSync(path.join(cacheDir, "good.record"), ENCRYPTED_RECORD);
    // The opaque id matches no chat, so publishing it would add a phantom friend. A
    // truncated cache yields no verified handles; the record decrypted, so this is not
    // a key failure and must not throw.
    fs.writeFileSync(friendsPath, '{"contacts": {"synthetic-id-0001": {"displayN');

    try {
        const failures: string[] = [];
        const locations = readFindMyFriendsFromSecureCache(cacheDir, friendsPath, KEY, name => failures.push(name));
        assert.deepEqual(locations, []);
        assert.deepEqual(failures, ["FriendCacheData.data"]);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});
