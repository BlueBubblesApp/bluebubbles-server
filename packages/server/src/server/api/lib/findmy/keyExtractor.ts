/**
 * Handles importing Apple Find My encryption keys (extracted by the user via an external
 * tool) into the BlueBubbles app data directory, and decrypting the Find My `LocalStorage.db`
 * using the imported `LocalStorage.key`.
 *
 * The key extraction procedure itself (attaching lldb to `findmylocateagent`/`FindMy` with
 * SIP/AMFI temporarily disabled) is NOT performed by BlueBubbles. Extraction must be done by
 * the user with a dedicated tool, and the resulting key files are then imported here.
 *
 * Credit: the key extraction procedure, the AES-256-CBC keystream-XOR decryption scheme for
 * `LocalStorage.db`, and this implementation's algorithm are all derived from the
 * findmy-key-extractor project by manonstreet:
 * https://github.com/manonstreet/findmy-key-extractor (MIT License)
 */
import fs from "fs";
import path from "path";
import { createCipheriv } from "crypto";
import { FileSystem } from "@server/fileSystem";

const PAGE_SIZE = 4096;
const RESERVED_OFFSET = 4084;
const RESERVED_LENGTH = 12;
const CONTENT_LENGTH = RESERVED_OFFSET;
const SQLITE_MAGIC = "SQLite format 3\x00";
const WAL_HEADER_SIZE = 32;
const WAL_FRAME_HEADER_SIZE = 24;
const LOCAL_STORAGE_KEY_LENGTH = 32;

export const FIND_MY_KEY_FILES = ["LocalStorage.key", "FMIPDataManager.bplist", "FMFDataManager.bplist"] as const;

export type FindMyKeyFile = (typeof FIND_MY_KEY_FILES)[number];

export type FindMyKeyImportResult = {
    imported: FindMyKeyFile[];
    missing: FindMyKeyFile[];
};

export type FindMyKeyPrerequisites = {
    hasLldb: boolean;
    hasPython3: boolean;
    hasPip3: boolean;
    isSipDisabled: boolean;
};

export class FindMyKeyExtractor {
    /**
     * Checks whether the tools/state required to run the external findmy-key-extractor
     * (https://github.com/manonstreet/findmy-key-extractor) are available on this Mac: lldb
     * (from the Xcode Command Line Tools), Python 3 + pip, and SIP being disabled (lldb cannot
     * attach to Apple platform binaries otherwise). The SIP check reuses
     * `FileSystem.isSipDisabled()`, the same check already used for the Private API
     * requirements list. The UI uses this to decide whether to show the key import options at
     * all, since a user without these prerequisites couldn't have produced key files to import
     * in the first place.
     */
    static async checkPrerequisites(): Promise<FindMyKeyPrerequisites> {
        const [hasLldb, hasPython3, hasPip3, isSipDisabled] = await Promise.all([
            FindMyKeyExtractor.commandExists("lldb"),
            FindMyKeyExtractor.commandExists("python3"),
            FindMyKeyExtractor.commandExists("pip3"),
            FileSystem.isSipDisabled()
        ]);

        return { hasLldb, hasPython3, hasPip3, isSipDisabled };
    }

    private static async commandExists(command: string): Promise<boolean> {
        try {
            const output = await FileSystem.execShellCommand(`command -v ${command}`);
            return (output ?? "").trim().length > 0;
        } catch {
            return false;
        }
    }

    /**
     * Copies the 3 Find My key files (LocalStorage.key, FMIPDataManager.bplist,
     * FMFDataManager.bplist) from a user-selected folder into the BlueBubbles app data
     * directory, so they persist across reboots/app restarts.
     *
     * @param sourceDir Folder containing the key files (e.g. the `keys/` output directory
     * produced by https://github.com/manonstreet/findmy-key-extractor)
     */
    static importFromFolder(sourceDir: string): FindMyKeyImportResult {
        if (!fs.existsSync(sourceDir) || !fs.statSync(sourceDir).isDirectory()) {
            throw new Error(`Source folder does not exist or is not a directory: ${sourceDir}`);
        }

        if (!fs.existsSync(FileSystem.findMyKeysDir)) {
            fs.mkdirSync(FileSystem.findMyKeysDir, { recursive: true });
        }

        const imported: FindMyKeyFile[] = [];
        const missing: FindMyKeyFile[] = [];

        for (const fileName of FIND_MY_KEY_FILES) {
            const sourcePath = path.join(sourceDir, fileName);
            if (!fs.existsSync(sourcePath)) {
                missing.push(fileName);
                continue;
            }

            fs.copyFileSync(sourcePath, path.join(FileSystem.findMyKeysDir, fileName));
            imported.push(fileName);
        }

        return { imported, missing };
    }

    /**
     * Returns which of the 3 key files have already been imported into the app data directory.
     */
    static getImportStatus(): Record<FindMyKeyFile, boolean> {
        return FIND_MY_KEY_FILES.reduce((acc, fileName) => {
            acc[fileName] = fs.existsSync(path.join(FileSystem.findMyKeysDir, fileName));
            return acc;
        }, {} as Record<FindMyKeyFile, boolean>);
    }

    /**
     * Decrypts the Find My `LocalStorage.db` (and its `-wal` file, if present) using the
     * previously-imported `LocalStorage.key`, and writes the result as a standard,
     * unencrypted SQLite database.
     *
     * Apple's `sqliteCodecCCCrypto` encrypts each 4096-byte page independently using an
     * AES-256-CBC keystream XOR (CTR-like) construction, keyed off the page number and 12
     * trailing plaintext "reserved" bytes on each page.
     *
     * @param outputPath Where to write the decrypted database. Defaults to
     * `LocalStorage_decrypted.sqlite` inside the Find My keys directory.
     * @returns The path the decrypted database was written to.
     */
    static decryptLocalStorageDb(outputPath?: string): string {
        const keyPath = path.join(FileSystem.findMyKeysDir, "LocalStorage.key");
        if (!fs.existsSync(keyPath)) {
            throw new Error("LocalStorage.key has not been imported yet");
        }

        const key = fs.readFileSync(keyPath);
        if (key.length !== LOCAL_STORAGE_KEY_LENGTH) {
            throw new Error(`Expected a ${LOCAL_STORAGE_KEY_LENGTH}-byte key, got ${key.length} bytes`);
        }

        const dbPath = FileSystem.findMyLocalStorageDb;
        if (!fs.existsSync(dbPath)) {
            throw new Error(`Encrypted LocalStorage.db not found at: ${dbPath}`);
        }

        let decrypted = FindMyKeyExtractor.decryptDatabase(key, fs.readFileSync(dbPath));

        const walPath = `${dbPath}-wal`;
        if (fs.existsSync(walPath)) {
            decrypted = FindMyKeyExtractor.applyWal(key, fs.readFileSync(walPath), decrypted);
        }

        const finalPath = outputPath ?? path.join(FileSystem.findMyKeysDir, "LocalStorage_decrypted.sqlite");
        fs.writeFileSync(finalPath, decrypted);
        return finalPath;
    }

    /**
     * Decrypts every page of the encrypted database and verifies that the result starts with
     * the standard SQLite file header.
     */
    private static decryptDatabase(key: Buffer, data: Buffer): Buffer {
        const numPages = Math.floor(data.length / PAGE_SIZE);
        if (numPages === 0) {
            throw new Error("LocalStorage.db is empty");
        }

        const pages: Buffer[] = [];
        for (let i = 0; i < numPages; i++) {
            const page = data.subarray(i * PAGE_SIZE, (i + 1) * PAGE_SIZE);
            pages.push(FindMyKeyExtractor.decryptPage(key, page, i));
        }

        const output = Buffer.concat(pages);
        if (output.subarray(0, SQLITE_MAGIC.length).toString("latin1") !== SQLITE_MAGIC) {
            throw new Error(
                "Decryption failed: page 0 does not contain the SQLite header (wrong key or corrupted database)"
            );
        }

        return output;
    }

    /**
     * Applies WAL frames on top of the decrypted database pages, decrypting each frame with
     * the same per-page keystream scheme.
     */
    private static applyWal(key: Buffer, walData: Buffer, dbPages: Buffer): Buffer {
        if (walData.length < WAL_HEADER_SIZE) return dbPages;

        let output = Buffer.from(dbPages);
        let offset = WAL_HEADER_SIZE;

        while (offset + WAL_FRAME_HEADER_SIZE + PAGE_SIZE <= walData.length) {
            const pgno = walData.readUInt32BE(offset);
            const framePage = walData.subarray(
                offset + WAL_FRAME_HEADER_SIZE,
                offset + WAL_FRAME_HEADER_SIZE + PAGE_SIZE
            );
            const pageIndex = pgno - 1;
            const decryptedPage = FindMyKeyExtractor.decryptPage(key, framePage, pageIndex);

            const neededLength = (pageIndex + 1) * PAGE_SIZE;
            if (neededLength > output.length) {
                output = Buffer.concat([output, Buffer.alloc(neededLength - output.length)]);
            }

            decryptedPage.copy(output, pageIndex * PAGE_SIZE);
            offset += WAL_FRAME_HEADER_SIZE + PAGE_SIZE;
        }

        return output;
    }

    /**
     * Decrypts a single 4096-byte page using the AES-256-CBC keystream XOR construction:
     * keystream = AES-256-CBC-ENCRYPT(key, IV, zeros[4096]), where IV = pgno(LE32) ++
     * reserved(12 bytes). Page 0's bytes 16-23 are stored in plaintext and must be restored
     * from the original encrypted page after decryption.
     */
    private static decryptPage(key: Buffer, pageData: Buffer, pageIndex: number): Buffer {
        const pgno = pageIndex + 1;
        const reserved = pageData.subarray(RESERVED_OFFSET, RESERVED_OFFSET + RESERVED_LENGTH);

        const iv = Buffer.alloc(16);
        iv.writeUInt32LE(pgno, 0);
        reserved.copy(iv, 4);

        const cipher = createCipheriv("aes-256-cbc", key, iv);
        cipher.setAutoPadding(false);
        const keystream = Buffer.concat([cipher.update(Buffer.alloc(PAGE_SIZE)), cipher.final()]);

        const decryptedContent = Buffer.alloc(CONTENT_LENGTH);
        for (let i = 0; i < CONTENT_LENGTH; i++) {
            decryptedContent[i] = pageData[i] ^ keystream[i];
        }

        const result = Buffer.concat([decryptedContent, reserved]);
        if (pageIndex === 0) {
            pageData.subarray(16, 24).copy(result, 16);
        }

        return result;
    }
}
