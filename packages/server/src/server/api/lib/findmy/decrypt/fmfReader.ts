import fs from "fs";
import path from "path";
import { FileSystem } from "@server/fileSystem";
import { decryptCacheBuffer } from "./cache";

/**
 * Reads friend display names from the encrypted FMF cache (`FriendCacheData.data`).
 *
 * The decrypted plaintext is a binary plist dict whose `contacts` map is keyed by
 * findMyId and holds `{ displayName, ... }` per friend.
 *
 * @returns A map of findMyId (trailing `~` stripped) -> displayName.
 */
export const readFmfContacts = async (fmfKey: Buffer): Promise<Record<string, string>> => {
    const cachePath = path.join(FileSystem.findMyFmfCacheDir, "FriendCacheData.data");
    if (!fs.existsSync(cachePath)) return {};

    const decrypted = await decryptCacheBuffer(fs.readFileSync(cachePath), fmfKey);
    const contacts = decrypted?.contacts;
    if (!contacts || typeof contacts !== "object") return {};

    const names: Record<string, string> = {};
    for (const [rawId, info] of Object.entries<any>(contacts)) {
        const id = rawId.replace(/~+$/, "");
        const displayName = info?.displayName;
        if (id && typeof displayName === "string" && displayName.length > 0) {
            names[id] = displayName;
        }
    }

    return names;
};
