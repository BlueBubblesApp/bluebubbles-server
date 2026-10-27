import * as crypto from "crypto";
import * as net from "net";

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const WEEK = 7 * DAY;

export type FailureRule = {
    label: string;
    windowMs: number;
    maxFailures: number;
    // Whether tripping this rule is worth an alert. A one-second cool-down is not.
    alert: boolean;
};

/**
 * Limits on DISTINCT wrong passwords from one client address. Repeating the
 * same wrong password counts once, so a client stuck retrying a stale password
 * never trips these, while guessing does.
 */
export const PER_ADDRESS_RULES: FailureRule[] = [
    { label: "second", windowMs: SECOND, maxFailures: 3, alert: false },
    { label: "minute", windowMs: MINUTE, maxFailures: 10, alert: true },
    { label: "24 hours", windowMs: DAY, maxFailures: 50, alert: true }
];

/**
 * Distinct wrong passwords across every address. This only raises an alert: a
 * global lockout would let one attacker lock out every legitimate client.
 */
export const GLOBAL_ALERT_RULE: FailureRule = { label: "week", windowMs: WEEK, maxFailures: 50, alert: true };

// Bounds memory if an attacker rotates source addresses.
const MAX_TRACKED_ADDRESSES = 10000;

type Failure = { at: number; credential: string };

type AddressState = {
    failures: Failure[];
    // Rule label -> time an alert for it was last raised
    alertedAt: Map<string, number>;
};

export type FailureOutcome = {
    // Set when this failure caused a block that warrants an alert
    blockAlert?: { address: string; rule: FailureRule; failures: number; retryAt: number };
    // Set when this failure pushed the global count over its threshold
    globalAlert?: { failures: number; addresses: number };
};

const stripPort = (value: string): string => {
    const v = value.trim();
    const bracketed = v.match(/^\[([^\]]+)\](?::\d+)?$/);
    if (bracketed) return bracketed[1];
    const v4WithPort = v.match(/^(\d{1,3}(?:\.\d{1,3}){3}):\d+$/);
    if (v4WithPort) return v4WithPort[1];
    return v;
};

export const normalizeAddress = (value: string | null | undefined): string | null => {
    if (!value) return null;
    let addr = stripPort(value).toLowerCase();
    if (addr.startsWith("::ffff:") && net.isIPv4(addr.substring(7))) addr = addr.substring(7);
    return net.isIP(addr) ? addr : null;
};

export const isLoopback = (addr: string): boolean => addr === "::1" || (net.isIPv4(addr) && addr.startsWith("127."));

/**
 * Addresses that may legitimately be a reverse proxy in front of the server:
 * this machine or the local network. Their X-Forwarded-For is trusted.
 */
export const isTrustedProxy = (addr: string): boolean => {
    if (isLoopback(addr)) return true;
    if (net.isIPv4(addr)) {
        const [a, b] = addr.split(".").map(Number);
        return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
    }
    // fc00::/7 (unique local) and fe80::/10 (link local)
    return /^f[cd]/.test(addr) || /^fe[89ab]/.test(addr);
};

/**
 * Works out which client a request came from.
 *
 * Koa's `ctx.request.ip` (with `proxy = true`) is the LEFTMOST X-Forwarded-For
 * entry, which the client writes itself, so an attacker could rotate it to
 * dodge a per-address limit. Instead, only honour X-Forwarded-For when the
 * direct peer is a local proxy, and take the rightmost entry that a proxy
 * appended for a non-local hop. If every hop is local, the leftmost entry is
 * the original LAN client.
 */
export const resolveClientAddress = (
    peerAddress: string | null | undefined,
    forwardedFor: string | string[] | null | undefined
): string | null => {
    const peer = normalizeAddress(peerAddress);
    if (!peer) return null;
    if (!isTrustedProxy(peer)) return peer;

    const header = Array.isArray(forwardedFor) ? forwardedFor.join(",") : forwardedFor ?? "";
    const hops = header
        .split(",")
        .map(normalizeAddress)
        .filter((e): e is string => !!e);
    if (hops.length === 0) return peer;

    for (let i = hops.length - 1; i >= 0; i--) {
        if (!isTrustedProxy(hops[i])) return hops[i];
    }

    return hops[0];
};

/**
 * Tracks failed password attempts and decides when a client address is blocked.
 * State is in memory only, so restarting the server clears every block.
 */
export class AuthThrottle {
    private addresses = new Map<string, AddressState>();

    private globalFailures: number[] = [];

    private globalAlertedAt: number = null;

    // Wrong passwords are only ever held as a keyed hash, never in the clear
    private hashKey = crypto.randomBytes(32);

    constructor(
        private rules: FailureRule[] = PER_ADDRESS_RULES,
        private globalRule: FailureRule = GLOBAL_ALERT_RULE
    ) {}

    /**
     * An address that cannot be attributed to one client (unknown, or this
     * machine, which is what every client looks like behind a proxy that does
     * not forward the client address) is never blocked: blocking it would lock
     * out every client sharing it.
     */
    static isAttributable(address: string | null): boolean {
        return !!address && !isLoopback(address);
    }

    /**
     * Returns the time at which `address` may try again, or 0 if it is not blocked.
     */
    retryAt(address: string | null, now = Date.now()): number {
        if (!AuthThrottle.isAttributable(address)) return 0;
        const state = this.addresses.get(address);
        if (!state) return 0;

        let retry = 0;
        for (const rule of this.rules) {
            const inWindow = state.failures.filter(f => f.at > now - rule.windowMs);
            if (inWindow.length >= rule.maxFailures) {
                retry = Math.max(retry, inWindow[inWindow.length - rule.maxFailures].at + rule.windowMs);
            }
        }

        return retry;
    }

    /**
     * Records a wrong password from `address`.
     */
    recordFailure(address: string | null, credential: string, now = Date.now()): FailureOutcome {
        const outcome: FailureOutcome = {};
        const longest = Math.max(...this.rules.map(r => r.windowMs));
        const key = AuthThrottle.isAttributable(address) ? address : null;
        const hash = crypto.createHmac("sha256", this.hashKey).update(credential ?? "").digest("hex");

        let state = key ? this.addresses.get(key) : null;
        if (state) {
            state.failures = state.failures.filter(f => f.at > now - longest);
            // A credential this address already got wrong is not a new guess
            if (state.failures.some(f => f.credential === hash)) return outcome;
        }

        this.globalFailures = this.globalFailures.filter(t => t > now - this.globalRule.windowMs);
        this.globalFailures.push(now);
        if (
            this.globalFailures.length >= this.globalRule.maxFailures &&
            (this.globalAlertedAt === null || now - this.globalAlertedAt >= this.globalRule.windowMs)
        ) {
            this.globalAlertedAt = now;
            outcome.globalAlert = { failures: this.globalFailures.length, addresses: this.addresses.size };
        }

        if (!key) return outcome;

        if (!state) {
            this.prune(now, longest);
            state = { failures: [], alertedAt: new Map() };
            this.addresses.set(key, state);
        }

        state.failures.push({ at: now, credential: hash });

        // Alert for the longest rule now tripped, once per rule window
        for (let i = this.rules.length - 1; i >= 0; i--) {
            const rule = this.rules[i];
            const count = state.failures.filter(f => f.at > now - rule.windowMs).length;
            if (count < rule.maxFailures) continue;
            if (!rule.alert) break;

            const last = state.alertedAt.get(rule.label);
            if (last === undefined || now - last >= rule.windowMs) {
                state.alertedAt.set(rule.label, now);
                outcome.blockAlert = { address: key, rule, failures: count, retryAt: this.retryAt(key, now) };
            }
            break;
        }

        return outcome;
    }

    /**
     * A correct password clears the address's failure history, so a user who
     * mistyped a few times starts again from zero. Only reachable while the
     * address is not blocked.
     */
    recordSuccess(address: string | null): void {
        if (address) this.addresses.delete(address);
    }

    get globalRuleLabel(): string {
        return this.globalRule.label;
    }

    reset(): void {
        this.addresses.clear();
        this.globalFailures = [];
        this.globalAlertedAt = null;
    }

    private prune(now: number, longest: number) {
        if (this.addresses.size < MAX_TRACKED_ADDRESSES) return;
        for (const [addr, state] of this.addresses) {
            if (!state.failures.some(f => f.at > now - longest)) this.addresses.delete(addr);
        }

        // Still full: drop the oldest entries (Map preserves insertion order)
        for (const addr of this.addresses.keys()) {
            if (this.addresses.size < MAX_TRACKED_ADDRESSES) break;
            this.addresses.delete(addr);
        }
    }
}
