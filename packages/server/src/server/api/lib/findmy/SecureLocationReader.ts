import crypto from "crypto";
import { execFileSync } from "child_process";
import fs from "fs";
import path from "path";
import bplistParser from "bplist-parser";
import { FindMyLocationItem } from "./types";

// Real records are ~656 B and there are 29 friends on the reference machine. These caps
// bound both memory and how long the synchronous read can block the main thread.
const MAX_RECORDS = 500;
const MAX_RECORD_BYTES = 64 * 1024;

export type SecureLocation = {
    latitude: number;
    longitude: number;
    timestamp: Date;
    horizontalAccuracy?: number;
    locationLabel?: string;
    findMyId?: string;
};

export type SecureLocationRecord = {
    identifier: string;
    secureLocation: SecureLocation;
};

const parseSinglePlistObject = (data: Buffer): any => {
    const parsed = bplistParser.parseBuffer(data);
    if (parsed.length !== 1) throw new Error(`Expected one plist object, got ${parsed.length}`);
    return parsed[0];
};

type SecurityExecutor = (file: string, args: readonly string[]) => string | Buffer;

// Bounded so a stalled Keychain prompt cannot block the server's event loop indefinitely.
const executeSecurity: SecurityExecutor = (file, args) =>
    execFileSync(file, [...args], { encoding: "utf8", timeout: 5000 });

export const loadBeaconStoreKey = (exec: SecurityExecutor = executeSecurity): Buffer => {
    let value: string;
    try {
        value = exec("/usr/bin/security", ["find-generic-password", "-s", "BeaconStore", "-a", "BeaconStoreKey", "-w"])
            .toString()
            .trim();
    } catch (ex: any) {
        // Never let the original error escape: execFileSync attaches captured stdout to
        // it, so the key rides on `error.stdout`/`error.output` even when the message
        // looks clean. Anything that logs the object (util.inspect, JSON.stringify, a
        // crash reporter) would then persist the secret.
        throw new Error(`/usr/bin/security exited with status ${ex?.status ?? "unknown"}`);
    }

    if (!/^[0-9a-fA-F]{64}$/.test(value)) {
        throw new Error("BeaconStoreKey must contain exactly 32 hex-encoded bytes");
    }

    return Buffer.from(value, "hex");
};

export const locationLabelForDisplay = (label?: string): string | null => {
    const normalized = label?.trim();
    return normalized && normalized !== "$null" ? normalized : null;
};

/** Shown when there is no Apple label or city yet: always true, unlike a generic placeholder. */
export const coordinateLabel = ([latitude, longitude]: [number, number]): string =>
    `${Math.abs(latitude).toFixed(3)}° ${latitude < 0 ? "S" : "N"}, ` +
    `${Math.abs(longitude).toFixed(3)}° ${longitude < 0 ? "W" : "E"}`;

export const decryptSecureLocationRecord = (encryptedRecord: Buffer, key: Buffer): SecureLocationRecord => {
    if (key.length !== 32) throw new Error(`Expected a 32-byte BeaconStore key, got ${key.length}`);

    const wrapper = parseSinglePlistObject(encryptedRecord);
    if (!Array.isArray(wrapper) || wrapper.length !== 3 || !wrapper.every(Buffer.isBuffer)) {
        throw new Error("SecureLocationCache record must contain nonce, authentication tag, and ciphertext");
    }

    const [nonce, authTag, ciphertext] = wrapper as [Buffer, Buffer, Buffer];
    if (nonce.length !== 16) throw new Error(`Expected a 16-byte nonce, got ${nonce.length}`);
    if (authTag.length !== 16) throw new Error(`Expected a 16-byte authentication tag, got ${authTag.length}`);

    const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
    decipher.setAuthTag(authTag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    const result = parseSinglePlistObject(plaintext) as SecureLocationRecord;

    // `typeof NaN === "number"` and an Invalid Date is still `instanceof Date`, so check
    // for finite values explicitly. JSON.stringify renders NaN/Infinity as null, which
    // would otherwise reach the client as `coordinates: [null, null]`.
    const location = result?.secureLocation;
    if (
        !location ||
        !Number.isFinite(location.latitude) ||
        !Number.isFinite(location.longitude) ||
        Math.abs(location.latitude) > 90 ||
        Math.abs(location.longitude) > 180 ||
        !(location.timestamp instanceof Date) ||
        !Number.isFinite(location.timestamp.getTime())
    ) {
        throw new Error("Decrypted SecureLocationCache record is missing required location fields");
    }

    return result;
};

type FriendContact = {
    displayName?: string;
    shortName?: string;
};

type FriendFollowing = {
    id?: string;
    invitationAcceptedHandles?: string[];
    invitationFromHandle?: string;
    invitationSentToHandle?: string;
};

type FriendCacheData = {
    contacts?: Record<string, FriendContact>;
    following?: FriendFollowing[];
};

/**
 * Maps Apple's opaque friend id to the friend's real phone/email handle.
 *
 * SecureLocationCache records identify a friend only by that opaque id, while the
 * Messages/FMFSessions path keys the shared cache by phone number or email. Emitting the
 * opaque id would add a second entry for the same person instead of updating theirs.
 */
const buildHandleMap = (following: FriendFollowing[]): Record<string, string> => {
    const handles: Record<string, string> = {};
    for (const friend of following) {
        if (!friend?.id) continue;
        const handle =
            friend.invitationAcceptedHandles?.find(value => typeof value === "string" && value.length > 0) ??
            friend.invitationFromHandle ??
            friend.invitationSentToHandle;
        if (handle) handles[friend.id] = handle;
    }

    return handles;
};

export const assertFindMyLocationsUsable = (locations: FindMyLocationItem[]): void => {
    if (locations.length === 0) throw new Error("SecureLocationCache returned no friend locations");

    // Age is deliberately not checked here. Stale coordinates are still the best
    // answer available, and the background refresh publishes newer ones over the
    // socket as they arrive. Failing the request instead falls through to the
    // Messages/FMFSessions path, which has no on-demand refresh on Monterey.
    const usable = locations.some(location => {
        const [latitude, longitude] = location.coordinates ?? [];
        if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return false;

        // (0, 0) is Apple's "no fix" sentinel, not a position in the Atlantic.
        return latitude !== 0 || longitude !== 0;
    });

    if (!usable) {
        throw new Error("SecureLocationCache returned no usable friend coordinates");
    }
};

export const assertFindMyLocationsFresh = (
    locations: FindMyLocationItem[],
    now = Date.now(),
    maxAgeMs = 5 * 60 * 1000
): void => {
    if (locations.length === 0) throw new Error("SecureLocationCache returned no friend locations");

    // Reject non-finite timestamps explicitly. Math.max(...) over any NaN returns NaN,
    // and every comparison against NaN is false, so folding them into the age check
    // would report arbitrarily stale data as fresh.
    const timestamps = locations.map(location => location.last_updated).filter(Number.isFinite);
    if (timestamps.length === 0) {
        throw new Error("SecureLocationCache locations are stale: no location carried a usable timestamp");
    }

    const ageMs = now - Math.max(...timestamps);
    if (ageMs > maxAgeMs) {
        throw new Error(
            `SecureLocationCache locations are stale: newest location is ${ageMs}ms old (limit: ${maxAgeMs}ms)`
        );
    }
};

export const readFindMyFriendsFromSecureCache = (
    cacheDir: string,
    friendsPath: string,
    key: Buffer,
    onRecordError: (name: string, error: unknown) => void = () => undefined
): FindMyLocationItem[] => {
    // Contact names are cosmetic, so a corrupt or truncated cache must not cost us
    // coordinates. Fall back to empty metadata and keep going.
    let friendData: FriendCacheData = {};
    try {
        const parsed = JSON.parse(fs.readFileSync(friendsPath, "utf8"));
        if (parsed && typeof parsed === "object") friendData = parsed as FriendCacheData;
    } catch (error) {
        onRecordError(path.basename(friendsPath), error);
    }

    const contacts = friendData.contacts && typeof friendData.contacts === "object" ? friendData.contacts : {};
    const handles = buildHandleMap(Array.isArray(friendData.following) ? friendData.following : []);
    const files = fs
        .readdirSync(cacheDir)
        .filter(name => name.endsWith(".record") && !name.startsWith("._"))
        .sort()
        .slice(0, MAX_RECORDS);
    const output: FindMyLocationItem[] = [];
    let readable = 0;
    let decrypted = 0;

    for (const name of files) {
        const file = path.join(cacheDir, name);

        // Only ever read regular files of a plausible size. readFileSync on a FIFO or
        // character device (a `*.record` symlink to /dev/zero, say) never returns, which
        // would block the Electron main thread forever — past any try/catch. lstat is
        // required here: stat follows the link and reports the target as a regular file.
        let stats: fs.Stats;
        try {
            stats = fs.lstatSync(file);
        } catch (error) {
            onRecordError(name, error);
            continue;
        }

        if (!stats.isFile() || stats.size === 0 || stats.size > MAX_RECORD_BYTES) continue;
        readable += 1;

        try {
            const record = decryptSecureLocationRecord(fs.readFileSync(file), key);
            decrypted += 1;
            const location = record.secureLocation;
            const findMyId = location.findMyId ?? record.identifier;
            const contact = contacts[findMyId];
            // Without a verified phone/email the record cannot be matched to a chat handle;
            // publishing Apple's opaque id would create a phantom friend entry.
            const handle = handles[findMyId];
            if (!handle) continue;

            // A (0,0) reading means "no fix", not the Gulf of Guinea. FindMyFriendsCache
            // only blocks zero-coordinate clobbering when both sides are "legacy", so
            // emitting one would replace a real location and ship as a live update.
            if (location.latitude === 0 && location.longitude === 0) continue;

            const displayLabel =
                locationLabelForDisplay(location.locationLabel) ??
                coordinateLabel([location.latitude, location.longitude]);

            output.push({
                handle,
                coordinates: [location.latitude, location.longitude],
                long_address: displayLabel,
                short_address: displayLabel,
                subtitle: null,
                title: contact?.displayName ?? contact?.shortName ?? handle,
                last_updated: location.timestamp.getTime(),
                is_locating_in_progress: false,
                // SecureLocationCache is a timestamped snapshot. Calling it "live" makes
                // the Android client hide its Last updated suffix, so use the client's
                // shallow status for a located-but-not-actively-locating record.
                status: "shallow"
            });
        } catch (error) {
            onRecordError(name, error);
        }
    }

    if (readable > 0 && decrypted === 0) {
        throw new Error(`Failed to decrypt all ${readable} SecureLocationCache records`);
    }

    return output;
};
