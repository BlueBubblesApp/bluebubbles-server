import dns from "dns";
import http from "http";
import https from "https";
import { isIP, isIPv4 } from "net";

/**
 * Per-webhook delivery restrictions
 */
export type WebhookSecurityOptions = {
    // Refuse to deliver to loopback, private, link-local or otherwise non-public addresses
    blockPrivateAddresses: boolean;
    // Refuse to deliver over plain HTTP
    requireHttps: boolean;
    // Follow 3xx redirects (each hop is held to the same restrictions)
    followRedirects: boolean;
};

export const DEFAULT_WEBHOOK_SECURITY_OPTIONS: WebhookSecurityOptions = {
    blockPrivateAddresses: false,
    requireHttps: false,
    followRedirects: false
};

export class WebhookUrlError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "WebhookUrlError";
    }
}

// [network, prefix length]
const BLOCKED_IPV4_RANGES: Array<[string, number]> = [
    ["0.0.0.0", 8], // "This" network
    ["10.0.0.0", 8], // Private (RFC 1918)
    ["100.64.0.0", 10], // Carrier-grade NAT (RFC 6598)
    ["127.0.0.0", 8], // Loopback
    ["169.254.0.0", 16], // Link-local (includes cloud metadata services)
    ["172.16.0.0", 12], // Private (RFC 1918)
    ["192.0.0.0", 24], // IETF protocol assignments
    ["192.168.0.0", 16], // Private (RFC 1918)
    ["198.18.0.0", 15], // Benchmarking
    ["224.0.0.0", 4], // Multicast
    ["240.0.0.0", 4] // Reserved + broadcast
];

const BLOCKED_IPV6_RANGES: Array<[string, number]> = [
    ["::", 96], // Unspecified, loopback and IPv4-compatible
    ["::ffff:0:0:0", 96], // IPv4-translated (RFC 2765)
    ["64:ff9b:1::", 48], // Local-use NAT64 (RFC 8215)
    ["fc00::", 7], // Unique local
    ["fe80::", 10], // Link-local
    ["fec0::", 10], // Site-local (deprecated, still routable on some networks)
    ["ff00::", 8] // Multicast
];

const ipv4ToNumber = (address: string): number =>
    address.split(".").reduce((acc, octet) => acc * 256 + Number.parseInt(octet, 10), 0);

const ipv6ToGroups = (address: string): number[] => {
    let value = address;

    // Convert a trailing dotted IPv4 section (e.g. ::ffff:127.0.0.1) into two hex groups
    const lastColon = value.lastIndexOf(":");
    const tail = value.substring(lastColon + 1);
    if (isIPv4(tail)) {
        const n = ipv4ToNumber(tail);
        value = `${value.substring(0, lastColon + 1)}${Math.floor(n / 65536).toString(16)}:${(n % 65536).toString(16)}`;
    }

    const [head, rest] = value.split("::");
    const headGroups = head ? head.split(":") : [];
    const restGroups = rest ? rest.split(":") : [];
    const fill = value.includes("::") ? 8 - headGroups.length - restGroups.length : 0;
    return [...headGroups, ...Array(fill).fill("0"), ...restGroups].map(g => Number.parseInt(g, 16));
};

const inIpv4Range = (address: string, [network, prefix]: [string, number]): boolean => {
    const size = 2 ** (32 - prefix);
    return Math.floor(ipv4ToNumber(address) / size) === Math.floor(ipv4ToNumber(network) / size);
};

const inIpv6Range = (groups: number[], [network, prefix]: [string, number]): boolean => {
    const networkGroups = ipv6ToGroups(network);
    for (let i = 0; i < 8; i++) {
        const bits = Math.min(16, Math.max(0, prefix - i * 16));
        if (bits === 0) return true;
        const size = 2 ** (16 - bits);
        if (Math.floor(groups[i] / size) !== Math.floor(networkGroups[i] / size)) return false;
    }

    return true;
};

/**
 * Returns true if an IP address is loopback, private, link-local or otherwise not publicly routable.
 * Unparseable input is treated as blocked.
 */
export const isBlockedAddress = (address: string): boolean => {
    // Strip IPv6 brackets and zone IDs (fe80::1%en0)
    const ip = address.replace(/^\[|\]$/g, "").split("%")[0];

    const version = isIP(ip);
    if (version === 4) return BLOCKED_IPV4_RANGES.some(r => inIpv4Range(ip, r));
    if (version !== 6) return true;

    const groups = ipv6ToGroups(ip.toLowerCase());
    if (groups.length !== 8 || groups.some(g => Number.isNaN(g))) return true;

    const embeddedIpv4 = (high: number, low: number) => [high >> 8, high & 0xff, low >> 8, low & 0xff].join(".");

    // IPv4-mapped (::ffff:a.b.c.d): check the embedded IPv4 address
    if (groups.slice(0, 5).every(g => g === 0) && groups[5] === 0xffff) {
        return BLOCKED_IPV4_RANGES.some(r => inIpv4Range(embeddedIpv4(groups[6], groups[7]), r));
    }

    // NAT64 (64:ff9b::a.b.c.d) is translated to the embedded IPv4 address by the network's gateway
    if (groups[0] === 0x64 && groups[1] === 0xff9b && groups.slice(2, 6).every(g => g === 0)) {
        return BLOCKED_IPV4_RANGES.some(r => inIpv4Range(embeddedIpv4(groups[6], groups[7]), r));
    }

    // 6to4 (2002:aabb:ccdd::) tunnels to the IPv4 address in the second and third groups
    if (groups[0] === 0x2002 && BLOCKED_IPV4_RANGES.some(r => inIpv4Range(embeddedIpv4(groups[1], groups[2]), r))) {
        return true;
    }

    return BLOCKED_IPV6_RANGES.some(r => inIpv6Range(groups, r));
};

/**
 * Parses and validates a webhook URL against the static (non-DNS) rules
 */
export const parseWebhookUrl = (url: string, options: Partial<WebhookSecurityOptions> = {}): URL => {
    let parsed: URL;
    try {
        parsed = new URL(url);
    } catch {
        throw new WebhookUrlError("Webhook URL is not a valid URL!");
    }

    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        throw new WebhookUrlError("Webhook URL must use the http or https scheme!");
    }

    if (options.requireHttps && parsed.protocol !== "https:") {
        throw new WebhookUrlError("Webhook URL must use https!");
    }

    if (!parsed.hostname) {
        throw new WebhookUrlError("Webhook URL must include a host!");
    }

    if (options.blockPrivateAddresses) {
        const host = parsed.hostname.replace(/^\[|\]$/g, "");
        if (isIP(host) && isBlockedAddress(host)) {
            throw new WebhookUrlError(`Webhook URL points to a local network address (${host})!`);
        }
    }

    return parsed;
};

/**
 * Validates a webhook URL, including resolving the host to make sure
 * none of its addresses are local when private addresses are blocked.
 */
export const validateWebhookUrl = async (url: string, options: Partial<WebhookSecurityOptions> = {}): Promise<URL> => {
    const parsed = parseWebhookUrl(url, options);
    if (!options.blockPrivateAddresses) return parsed;

    const host = parsed.hostname.replace(/^\[|\]$/g, "");
    if (isIP(host)) return parsed;

    let addresses: dns.LookupAddress[];
    try {
        addresses = await dns.promises.lookup(host, { all: true });
    } catch (ex: any) {
        throw new WebhookUrlError(`Unable to resolve webhook host "${host}": ${ex?.message ?? String(ex)}`);
    }

    const blocked = addresses.find(a => isBlockedAddress(a.address));
    if (blocked) {
        throw new WebhookUrlError(`Webhook host "${host}" resolves to a local network address (${blocked.address})!`);
    }

    return parsed;
};

/**
 * A DNS lookup that refuses to connect to blocked addresses. Because the socket connects
 * to the address returned here, a host can't pass validation and then rebind to a local address.
 */
const guardedLookup = (hostname: string, options: any, callback: (...args: any[]) => void) => {
    if (typeof options === "function") {
        callback = options;
        options = {};
    } else if (typeof options === "number") {
        options = { family: options };
    }

    dns.lookup(hostname, { ...options, all: true }, (err, addresses: dns.LookupAddress[]) => {
        if (err) return callback(err);

        const blocked = addresses.find(a => isBlockedAddress(a.address));
        if (blocked) {
            const message = `Webhook host "${hostname}" resolved to a local network address (${blocked.address})`;
            return callback(new WebhookUrlError(message));
        }

        if (options?.all) return callback(null, addresses);
        return callback(null, addresses[0].address, addresses[0].family);
    });
};

export const guardedHttpAgent = new http.Agent({ lookup: guardedLookup } as http.AgentOptions);
export const guardedHttpsAgent = new https.Agent({ lookup: guardedLookup } as https.AgentOptions);
