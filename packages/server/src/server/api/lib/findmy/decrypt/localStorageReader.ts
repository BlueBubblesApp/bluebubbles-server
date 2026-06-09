import fs from "fs";
import path from "path";
import { FileSystem } from "@server/fileSystem";
import { uuidv4 } from "@firebase/util";
import { decryptLocalStorageDb } from "./localStorage";

// better-sqlite3 and bplist-parser are runtime deps; require directly for sync use here
// eslint-disable-next-line @typescript-eslint/no-var-requires
const Database = require("better-sqlite3");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const bplist = require("bplist-parser");

export type RawFriendLocation = {
    /** Stable Find My identifier (serverUserID / serverID), trailing `~` stripped. */
    findMyId: string;
    /** Owner handle (email / phone) if resolvable from the `friends` table. */
    handle: string | null;
    /** Full parsed `secureLocations.value` plist (lat/long/timestamp/accuracy/...). */
    location: Record<string, any>;
};

const stripPadding = (id: string): string => (id ?? "").replace(/~+$/, "");

/**
 * Decrypt LocalStorage.db to a temporary plaintext SQLite file, run `fn` against it,
 * then delete the temp file. The plaintext contains real private coordinates, so it is
 * always cleaned up — even on error.
 */
const withDecryptedDb = <T>(key: Buffer, fn: (db: any) => T): T => {
    const tmpPath = path.join(FileSystem.baseDir, `findmy-localstorage-${uuidv4()}.sqlite`);
    const decrypted = decryptLocalStorageDb(key, FileSystem.findMyLocalStorageDbPath);
    fs.writeFileSync(tmpPath, decrypted, { mode: 0o600 });

    let db: any = null;
    try {
        db = new Database(tmpPath, { readonly: true, fileMustExist: true });
        return fn(db);
    } finally {
        try {
            db?.close();
        } catch {
            // ignore
        }
        try {
            fs.unlinkSync(tmpPath);
        } catch {
            // ignore
        }
    }
};

/** Returns the set of column names for a table (empty if the table doesn't exist). */
const tableColumns = (db: any, table: string): Set<string> => {
    try {
        const rows = db.prepare(`PRAGMA table_info(${table})`).all();
        return new Set(rows.map((r: any) => r.name));
    } catch {
        return new Set();
    }
};

/**
 * Reads and joins friend coordinates from the decrypted LocalStorage.db.
 *
 * - `secureLocations` holds one coordinate plist per friend (keyed by serverUserID).
 * - `friends` maps serverID -> handleIdentifier (email/phone).
 */
export const readFriendLocations = (key: Buffer): RawFriendLocation[] => {
    return withDecryptedDb(key, (db): RawFriendLocation[] => {
        // Build findMyId -> handle map from the friends table (defensive about column names).
        // Real schema: handleServerIdentifier (= findMyId) maps to handleIdentifier (email/phone).
        // A single findMyId can have multiple handle rows (e.g. an email and a phone) — prefer email.
        const handleById: Record<string, string> = {};
        const friendCols = tableColumns(db, "friends");
        const idCol = friendCols.has("handleServerIdentifier")
            ? "handleServerIdentifier"
            : friendCols.has("serverID")
            ? "serverID"
            : null;
        const handleCol = friendCols.has("handleIdentifier") ? "handleIdentifier" : null;
        if (idCol && handleCol) {
            const rows = db.prepare(`SELECT ${idCol} as fid, ${handleCol} as handle FROM friends`).all();
            for (const row of rows) {
                const fid = stripPadding(String(row.fid ?? ""));
                const handle = row.handle ? String(row.handle) : null;
                if (!fid || !handle) continue;
                // Prefer an email-style handle when multiple exist for the same friend
                if (!handleById[fid] || (!handleById[fid].includes("@") && handle.includes("@"))) {
                    handleById[fid] = handle;
                }
            }
        }

        const out: RawFriendLocation[] = [];
        const locCols = tableColumns(db, "secureLocations");
        if (!locCols.has("value")) return out;

        const locIdCol = locCols.has("serverUserID") ? "serverUserID" : locCols.has("serverID") ? "serverID" : null;
        if (!locIdCol) return out;

        const rows = db.prepare(`SELECT ${locIdCol} as id, value FROM secureLocations`).all();
        for (const row of rows) {
            const fid = stripPadding(String(row.id ?? ""));
            if (!fid || row.value == null) continue;

            try {
                const valueBuf = Buffer.isBuffer(row.value) ? row.value : Buffer.from(row.value);
                const parsed = bplist.parseBuffer(valueBuf)[0];
                out.push({
                    findMyId: fid,
                    handle: handleById[fid] ?? null,
                    location: parsed
                });
            } catch {
                // skip unparseable rows
            }
        }

        return out;
    });
};

/**
 * Diagnostic helper: dump the schema (tables + columns) and row counts of the decrypted
 * LocalStorage.db. Used to locate where address strings are stored on a real machine.
 */
export const dumpLocalStorageSchema = (key: Buffer): Record<string, { columns: string[]; rowCount: number }> => {
    return withDecryptedDb(key, (db) => {
        const tables: { name: string }[] = db
            .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`)
            .all();

        const schema: Record<string, { columns: string[]; rowCount: number }> = {};
        for (const { name } of tables) {
            const columns = [...tableColumns(db, name)];
            let rowCount = 0;
            try {
                rowCount = (db.prepare(`SELECT COUNT(*) as c FROM "${name}"`).get() as any).c;
            } catch {
                // ignore
            }
            schema[name] = { columns, rowCount };
        }

        return schema;
    });
};
