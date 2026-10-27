import { createHash, randomBytes } from "crypto";


export const generateMd5Hash = (data: Buffer): string => {
    return createHash("md5").update(data).digest("hex");
};

export const generateRandomString = (length: number): string => {
    return randomBytes(Math.ceil(length / 2)).toString('hex');
};

// Google's limits on a project ID: 6 to 30 characters, starting with a letter.
const PROJECT_ID_MAX_LENGTH = 30;
const PROJECT_ID_MIN_SUFFIX = 6;

// Lowercase letters and digits, minus the ambiguous l, o, 0 and 1. Exactly 32 symbols,
// so masking a random byte to 5 bits picks one without modulo bias.
const PROJECT_ID_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";

/**
 * Generates a Google Cloud project ID that cannot be enumerated.
 *
 * Anyone who knows a project ID can read that project's server URL, so the random suffix
 * takes every character the 30-character limit leaves after the prefix (18 with
 * "bluebubbles", 90 bits), drawn from the CSPRNG. The old scheme was 4 hex characters:
 * 65,536 possibilities.
 *
 * @param prefix Kept for recognisability in the Google Cloud console
 * @returns The project ID
 */
export const generateProjectId = (prefix = "bluebubbles"): string => {
    let stem = prefix.toLowerCase().replace(/[^a-z0-9-]/g, "");
    if (!/^[a-z]/.test(stem)) stem = "bluebubbles";
    stem = stem.slice(0, PROJECT_ID_MAX_LENGTH - PROJECT_ID_MIN_SUFFIX - 1);

    // Leave room for the separating hyphen
    const suffixLength = PROJECT_ID_MAX_LENGTH - stem.length - 1;
    const suffix = Array.from(randomBytes(suffixLength), byte => PROJECT_ID_ALPHABET[byte & 31]).join("");
    return `${stem}-${suffix}`;
};