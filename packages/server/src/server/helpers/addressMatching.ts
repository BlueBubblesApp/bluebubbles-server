/**
 * Address comparison used to resolve a message handle (phone number, email,
 * or short code) to a saved contact.
 *
 * The rules are deliberately strict, so an unrelated sender never resolves to a
 * contact:
 *  - Emails (and any other non-numeric address) only match exactly, ignoring case.
 *  - Short numbers (fewer than MIN_TOLERANT_DIGITS digits, e.g. SMS short codes)
 *    only match exactly.
 *  - Longer phone numbers may differ by a country code of up to 3 digits on one
 *    side, and a single trunk-prefix "0" on the other. The rest of the number
 *    must be identical.
 */

// Shortest national number that is allowed to match with a country code missing.
// Anything shorter (short codes, partial numbers) must match exactly.
const MIN_TOLERANT_DIGITS = 7;

// Longest country code (ITU E.164 country codes are 1 to 3 digits)
const MAX_COUNTRY_CODE_DIGITS = 3;

export type NormalizedAddress = { kind: "phone" | "other"; value: string };

/**
 * Normalizes an address for comparison.
 *
 * @param address The raw address (handle ID or contact address)
 * @returns The normalized address, or null if there is nothing to compare
 */
export const normalizeAddress = (address: string): NormalizedAddress | null => {
    if (typeof address !== "string") return null;
    const trimmed = address.trim().toLowerCase();
    if (trimmed.length === 0) return null;

    // Emails, and anything else containing letters, are compared as-is
    if (trimmed.includes("@") || /[a-z]/.test(trimmed)) {
        return { kind: "other", value: trimmed };
    }

    // "+44 (0)7700 900123": the bracketed 0 is the national trunk prefix, which is never dialled
    // after a country code, so drop it before the digits are compared
    const digits = trimmed.replace(/\(\s*0\s*\)/g, "").replace(/\D/g, "");
    if (digits.length === 0) return null;
    return { kind: "phone", value: digits };
};

/**
 * Checks if two phone numbers (digits only) are the same number, written with
 * and without a country code (and/or with a national trunk prefix).
 *
 * Examples that match: 15550100123 / 5550100123, 447700900123 / 07700900123
 * Examples that don't: 47173 / 22273, 5550100123 / 6660100123, 47173 / 173
 */
const phonesMatchIgnoringCountryCode = (a: string, b: string): boolean => {
    const [longer, shorter] = a.length >= b.length ? [a, b] : [b, a];

    // The shorter number may carry a trunk prefix that the international form drops
    const national = shorter.startsWith("0") ? shorter.substring(1) : shorter;
    if (national.length < MIN_TOLERANT_DIGITS) return false;

    const prefixLength = longer.length - national.length;
    if (prefixLength < 1 || prefixLength > MAX_COUNTRY_CODE_DIGITS) return false;
    return longer.endsWith(national);
};

/**
 * Checks if two normalized addresses refer to the same handle
 *
 * @param a The first address
 * @param b The second address
 * @param exactOnly Whether to only allow an exact match
 */
export const addressesMatch = (a: NormalizedAddress, b: NormalizedAddress, exactOnly = false): boolean => {
    if (!a || !b || a.kind !== b.kind) return false;
    if (a.value === b.value) return true;
    return a.kind === "phone" && !exactOnly && phonesMatchIgnoringCountryCode(a.value, b.value);
};

/**
 * Finds the first candidate matching the address. An exact match anywhere in the
 * list takes precedence over a match that ignores the country code.
 *
 * @param address The address to look up
 * @param candidates The list of candidates to search
 * @param getAddresses Returns the addresses belonging to a candidate
 * @returns The matching candidate, or null if none match
 */
export const findByAddress = <T>(
    address: string,
    candidates: T[],
    getAddresses: (candidate: T) => string[]
): T | null => findInAddressIndex(address, buildAddressIndex(candidates, getAddresses));

export type AddressIndex<T> = Array<{ candidate: T; addresses: NormalizedAddress[] }>;

/**
 * Normalizes every candidate's addresses once, so a list that is searched
 * repeatedly (e.g. the contact list) isn't re-normalized on every lookup.
 *
 * @param candidates The list of candidates to index
 * @param getAddresses Returns the addresses belonging to a candidate
 */
export const buildAddressIndex = <T>(candidates: T[], getAddresses: (candidate: T) => string[]): AddressIndex<T> =>
    candidates.map(candidate => ({
        candidate,
        addresses: getAddresses(candidate)
            .map(normalizeAddress)
            .filter((e): e is NormalizedAddress => e !== null)
    }));

/**
 * Same as findByAddress, over a list indexed with buildAddressIndex
 */
export const findInAddressIndex = <T>(address: string, normalized: AddressIndex<T>): T | null => {
    const target = normalizeAddress(address);
    if (!target) return null;

    for (const exactOnly of [true, false]) {
        const match = normalized.find(e => e.addresses.some(addr => addressesMatch(target, addr, exactOnly)));
        if (match) return match.candidate;
    }

    return null;
};
