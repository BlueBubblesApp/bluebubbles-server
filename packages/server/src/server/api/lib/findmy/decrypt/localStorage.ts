import fs from "fs";
import crypto from "crypto";

/**
 * Decryption for Apple Find My's encrypted `LocalStorage.db` (friend coordinates).
 *
 * This is NOT standard SQLCipher. Apple's `sqliteCodecCCCrypto` encrypts each 4096-byte
 * SQLite page independently using an AES-256 keystream-XOR (CTR-like) construction:
 *   keystream = AES-256-CBC-ENCRYPT(key, iv, zeros[4096])
 *   plaintext = ciphertext[0:4084] XOR keystream[0:4084]
 * where iv = LE32(pgno) ‖ reserved(12 bytes from the page tail), pgno = page_index + 1.
 *
 * Ported from findmy-key-extractor/decrypt_localstorage.py.
 */

const PAGE_SIZE = 4096;
const RESERVED_OFF = 4084;
const RESERVED_LEN = 12;
const CONTENT_LEN = RESERVED_OFF; // 4084 encrypted bytes per page
const SQLITE_MAGIC = Buffer.from("SQLite format 3\0", "binary");

const WAL_HEADER_SIZE = 32;
const WAL_FRAME_HEADER_SIZE = 24;

/**
 * Decrypt a single 4096-byte page using AES-256-CBC keystream XOR.
 */
const decryptPage = (key: Buffer, page: Buffer, pageIndex: number): Buffer => {
    const pgno = pageIndex + 1;
    const reserved = page.subarray(RESERVED_OFF, RESERVED_OFF + RESERVED_LEN);

    const iv = Buffer.alloc(16);
    iv.writeUInt32LE(pgno, 0);
    reserved.copy(iv, 4);

    // Generate the keystream by CBC-*encrypting* zeros (autopadding off so output stays 4096 bytes)
    const cipher = crypto.createCipheriv("aes-256-cbc", key, iv);
    cipher.setAutoPadding(false);
    const keystream = Buffer.concat([cipher.update(Buffer.alloc(PAGE_SIZE)), cipher.final()]);

    const decrypted = Buffer.alloc(CONTENT_LEN);
    for (let i = 0; i < CONTENT_LEN; i++) {
        decrypted[i] = page[i] ^ keystream[i];
    }

    const result = Buffer.concat([decrypted, reserved]);

    // Page 0 fix-up: bytes 16-23 (page size / format versions) are stored in plaintext
    if (pageIndex === 0) {
        page.copy(result, 16, 16, 24);
    }

    return result;
};

/**
 * Decrypt every page of the database file buffer.
 * @throws if page 0 does not decrypt to a valid SQLite header (wrong key / corrupt db).
 */
const decryptDatabaseBuffer = (key: Buffer, data: Buffer): Buffer => {
    const numPages = Math.floor(data.length / PAGE_SIZE);
    if (numPages === 0) throw new Error("LocalStorage.db is empty");

    const pages: Buffer[] = [];
    for (let i = 0; i < numPages; i++) {
        const page = data.subarray(i * PAGE_SIZE, (i + 1) * PAGE_SIZE);
        pages.push(decryptPage(key, page, i));
    }

    const output = Buffer.concat(pages);
    if (!output.subarray(0, 16).equals(SQLITE_MAGIC)) {
        throw new Error("LocalStorage.db decryption failed — page 0 is not a SQLite header (wrong key?)");
    }

    return output;
};

/**
 * Apply WAL frames on top of the decrypted database (newest committed pages).
 */
const applyWal = (key: Buffer, walData: Buffer, dbPages: Buffer): Buffer => {
    if (walData.length < WAL_HEADER_SIZE) return dbPages;

    let output = dbPages;
    let offset = WAL_HEADER_SIZE;
    while (offset + WAL_FRAME_HEADER_SIZE + PAGE_SIZE <= walData.length) {
        // Frame header: pgno is a big-endian uint32 at offset 0
        const pgno = walData.readUInt32BE(offset);
        const pageIndex = pgno - 1;
        const framePage = walData.subarray(
            offset + WAL_FRAME_HEADER_SIZE,
            offset + WAL_FRAME_HEADER_SIZE + PAGE_SIZE
        );
        const decrypted = decryptPage(key, framePage, pageIndex);

        // Grow the db if the WAL references pages beyond the current size
        const needed = (pageIndex + 1) * PAGE_SIZE;
        if (needed > output.length) {
            output = Buffer.concat([output, Buffer.alloc(needed - output.length)]);
        }

        decrypted.copy(output, pageIndex * PAGE_SIZE);
        offset += WAL_FRAME_HEADER_SIZE + PAGE_SIZE;
    }

    return output;
};

/**
 * Decrypt LocalStorage.db (+ WAL if present) into a plaintext SQLite buffer.
 *
 * @param key 32-byte LocalStorage key
 * @param dbPath Path to the encrypted LocalStorage.db
 * @param walPath Optional path to LocalStorage.db-wal (defaults to `${dbPath}-wal`)
 */
export const decryptLocalStorageDb = (key: Buffer, dbPath: string, walPath?: string): Buffer => {
    if (key.length !== 32) throw new Error(`Expected 32-byte LocalStorage key, got ${key.length}`);

    const data = fs.readFileSync(dbPath);
    let output = decryptDatabaseBuffer(key, data);

    const resolvedWalPath = walPath ?? `${dbPath}-wal`;
    if (fs.existsSync(resolvedWalPath)) {
        const walData = fs.readFileSync(resolvedWalPath);
        if (walData.length > WAL_HEADER_SIZE) {
            output = applyWal(key, walData, output);
        }
    }

    return output;
};
