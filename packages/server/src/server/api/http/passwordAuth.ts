import * as crypto from "crypto";
import { Server } from "@server";

export type PasswordCheckResult = "ok" | "missing" | "unset" | "invalid";

/**
 * Normalizes a client-supplied credential. Query params can be arrays
 * (e.g. `?password=a&password=b`) or absent, so anything that isn't a
 * single string is treated as missing.
 */
const normalizeToken = (token: unknown): string | null => {
    if (typeof token !== "string") return null;
    const trimmed = token.trim();
    return trimmed.length > 0 ? trimmed : null;
};

/**
 * Compares two strings in constant time (with respect to their contents)
 */
const safeEquals = (a: string, b: string): boolean => {
    const aHash = crypto.createHash("sha256").update(a, "utf8").digest();
    const bHash = crypto.createHash("sha256").update(b, "utf8").digest();
    return crypto.timingSafeEqual(aHash, bHash);
};

/**
 * Pulls the password out of a Socket.IO handshake query (`password`, or the legacy `guid`).
 * Clients may URL-encode it a second time, so it's decoded once more; a malformed
 * sequence (e.g. a lone "%") throws, so the raw value is used instead.
 */
export const getSocketPassword = (query: Record<string, unknown> | null | undefined): unknown => {
    const pass = query?.password ?? query?.guid;
    if (typeof pass !== "string") return pass;

    try {
        return decodeURI(pass);
    } catch {
        return pass;
    }
};

/**
 * Checks a client-supplied credential against the server password.
 *
 * The configured password is read fresh every time and is never coerced with `String()`,
 * so a missing value can't turn into the literal string "null" or "undefined". An empty
 * (or missing) configured password never authenticates anyone.
 */
export const checkServerPassword = (token: unknown): PasswordCheckResult => {
    const provided = normalizeToken(token);
    if (provided === null) return "missing";

    // The config cache converts numeric-looking values (e.g. "1234" -> 1234), so primitives are
    // stringified to keep matching what clients already send. Only null/undefined mean "no password".
    const configured = Server().repo.getConfig("password");
    if (configured === null || configured === undefined) return "unset";
    const expected = normalizeToken(configured instanceof Date ? null : String(configured));
    if (expected === null) return "unset";

    return safeEquals(provided, expected) ? "ok" : "invalid";
};
