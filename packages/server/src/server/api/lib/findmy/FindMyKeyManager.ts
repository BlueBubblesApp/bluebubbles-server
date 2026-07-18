import fs from "fs";
import path from "path";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { parsePlistFile, extractSymmetricKey } from "./decrypt/plistUtils";
import { decryptLocalStorageDb } from "./decrypt/localStorage";
import { decryptCacheBuffer } from "./decrypt/cache";

export type FindMyKeyType = "LocalStorage" | "FMIP" | "FMF";

/** Canonical file names for each key, as produced by findmy-key-extractor. */
export const FIND_MY_KEY_FILES: Record<FindMyKeyType, string> = {
    LocalStorage: "LocalStorage.key",
    FMIP: "FMIPDataManager.bplist",
    FMF: "FMFDataManager.bplist"
};

export type FindMyKeyStatus = {
    /** The key file exists in the BlueBubbles keys directory. */
    present: boolean;
    /** The key file is well-formed (correct length / parseable). */
    valid: boolean;
};

export type FindMyKeysStatus = Record<FindMyKeyType, FindMyKeyStatus>;

export type KeyImportResult = "imported" | "invalid" | "missing";

/**
 * Loads, validates, caches, and imports the three Find My decryption keys.
 *
 * Keys are stored in `FileSystem.findMyKeysDir` and are stable across reboots
 * (derived from the user's iCloud account), so they only need to be imported once.
 */
export class FindMyKeyManager {
    private static cache: Partial<Record<FindMyKeyType, Buffer>> = {};

    private static keyPath(type: FindMyKeyType): string {
        return path.join(FileSystem.findMyKeysDir, FIND_MY_KEY_FILES[type]);
    }

    /** Clears the in-memory key cache (call after a re-import). */
    static clearCache(): void {
        this.cache = {};
    }

    /**
     * Loads and returns the 32-byte LocalStorage key (raw bytes), or null if unavailable.
     */
    static loadLocalStorageKey(): Buffer | null {
        if (this.cache.LocalStorage) return this.cache.LocalStorage;

        const keyPath = this.keyPath("LocalStorage");
        if (!fs.existsSync(keyPath)) return null;

        const key = fs.readFileSync(keyPath);
        if (key.length !== 32) {
            Server().logger.debug(`Invalid LocalStorage key length: ${key.length} bytes, expected 32`);
            return null;
        }

        this.cache.LocalStorage = key;
        return key;
    }

    /**
     * Loads and returns a 32-byte ChaCha20 cache key (FMIP or FMF), or null if unavailable.
     */
    static async loadCacheKey(type: "FMIP" | "FMF"): Promise<Buffer | null> {
        if (this.cache[type]) return this.cache[type] as Buffer;

        const keyPath = this.keyPath(type);
        if (!fs.existsSync(keyPath)) return null;

        try {
            const plistData = await parsePlistFile(keyPath);
            const key = extractSymmetricKey(plistData);
            if (!key) {
                Server().logger.debug(`Could not extract a valid 32-byte ${type} key from ${keyPath}`);
                return null;
            }

            this.cache[type] = key;
            return key;
        } catch (ex: any) {
            Server().logger.debug(`Failed to load ${type} key: ${String(ex)}`);
            return null;
        }
    }

    /**
     * Returns presence/validity for all three keys (used by the UI status card).
     */
    static async getStatus(): Promise<FindMyKeysStatus> {
        const status = {} as FindMyKeysStatus;

        for (const type of Object.keys(FIND_MY_KEY_FILES) as FindMyKeyType[]) {
            const present = fs.existsSync(this.keyPath(type));
            let valid = false;
            if (present) {
                try {
                    const key =
                        type === "LocalStorage" ? this.loadLocalStorageKey() : await this.loadCacheKey(type);
                    valid = key != null;
                } catch {
                    valid = false;
                }
            }

            status[type] = { present, valid };
        }

        return status;
    }

    /**
     * Validates a candidate key file (before importing it).
     *
     * - LocalStorage: 32 raw bytes; if the encrypted db is present, page 0 must decrypt
     *   to a valid SQLite header.
     * - FMIP/FMF: bplist must yield a 32-byte symmetric key; if a matching cache file is
     *   present, it must decrypt (Poly1305 tag verifies correctness).
     */
    static async validateKeyFile(type: FindMyKeyType, filePath: string): Promise<boolean> {
        try {
            if (type === "LocalStorage") {
                const key = fs.readFileSync(filePath);
                if (key.length !== 32) return false;

                // Deep check against real data when available
                if (fs.existsSync(FileSystem.findMyLocalStorageDbPath)) {
                    decryptLocalStorageDb(key, FileSystem.findMyLocalStorageDbPath);
                }
                return true;
            }

            const plistData = await parsePlistFile(filePath);
            const key = extractSymmetricKey(plistData);
            if (!key) return false;

            // Deep check: try decrypting a real cache file if one exists
            const cacheFile =
                type === "FMIP"
                    ? path.join(FileSystem.findMyDir, "Devices.data")
                    : path.join(FileSystem.findMyFmfCacheDir, "FriendCacheData.data");
            if (fs.existsSync(cacheFile)) {
                const decrypted = await decryptCacheBuffer(fs.readFileSync(cacheFile), key);
                if (decrypted == null) return false;
            }

            return true;
        } catch (ex: any) {
            Server().logger.debug(`Validation failed for ${type} key at ${filePath}: ${String(ex)}`);
            return false;
        }
    }

    /**
     * Imports keys from a directory (e.g. findmy-key-extractor's `keys/` folder).
     *
     * Auto-detects the three key files by name, validates each, and copies the valid
     * ones into `FileSystem.findMyKeysDir`. Returns a per-key import result.
     */
    static async importFromDirectory(sourceDir: string): Promise<Record<FindMyKeyType, KeyImportResult>> {
        const result = {} as Record<FindMyKeyType, KeyImportResult>;

        if (!fs.existsSync(FileSystem.findMyKeysDir)) {
            fs.mkdirSync(FileSystem.findMyKeysDir, { recursive: true });
        }

        for (const type of Object.keys(FIND_MY_KEY_FILES) as FindMyKeyType[]) {
            const fileName = FIND_MY_KEY_FILES[type];
            const src = path.join(sourceDir, fileName);

            if (!fs.existsSync(src)) {
                result[type] = "missing";
                continue;
            }

            const isValid = await this.validateKeyFile(type, src);
            if (!isValid) {
                result[type] = "invalid";
                continue;
            }

            fs.copyFileSync(src, this.keyPath(type));
            result[type] = "imported";
        }

        // Refresh the in-memory cache so newly imported keys take effect immediately
        this.clearCache();
        return result;
    }
}
