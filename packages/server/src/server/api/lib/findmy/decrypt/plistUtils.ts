import fs from "fs";
import plist from "plist";
import * as bplist from "bplist-parser";

/**
 * Parse a plist file, transparently supporting both binary ("bplist") and XML plists.
 */
export const parsePlistFile = async (filePath: string): Promise<any> => {
    const fileData = fs.readFileSync(filePath);
    return parsePlistBuffer(fileData);
};

/**
 * Parse a plist from an in-memory buffer (binary or XML).
 */
export const parsePlistBuffer = async (buffer: Buffer): Promise<any> => {
    if (buffer.toString("utf8", 0, 6) === "bplist") {
        const result = await bplist.parseBuffer(buffer);
        // bplist-parser returns an array of top-level objects; the first is the root
        return result[0];
    }

    return plist.parse(buffer.toString("utf8"));
};

/**
 * Extracts the 32-byte ChaCha20 symmetric key from a FMIP/FMF DataManager bplist.
 *
 * The keychain bplist nests the raw key as: symmetricKey -> key -> data.
 * Older/alternate formats may store the key directly as a base64 string.
 *
 * @returns The 32-byte key buffer, or null if it could not be extracted.
 */
export const extractSymmetricKey = (plistData: any): Buffer | null => {
    const symmetricKey = plistData?.symmetricKey;
    if (!symmetricKey) return null;

    let keyBytes: Buffer | null = null;
    if (typeof symmetricKey === "object" && symmetricKey.key?.data != null) {
        const data = symmetricKey.key.data;
        keyBytes = Buffer.isBuffer(data) ? data : Buffer.from(data, "base64");
    } else if (typeof symmetricKey === "string") {
        keyBytes = Buffer.from(symmetricKey, "base64");
    }

    if (!keyBytes || keyBytes.length !== 32) return null;
    return keyBytes;
};
