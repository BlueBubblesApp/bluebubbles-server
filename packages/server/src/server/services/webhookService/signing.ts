import { createHmac } from "crypto";

export const WEBHOOK_SIGNATURE_HEADER = "x-bluebubbles-signature";
export const WEBHOOK_TIMESTAMP_HEADER = "x-bluebubbles-timestamp";

/**
 * Builds the authentication headers for an outbound webhook request.
 *
 * The signature is computed as HMAC-SHA256 over `<timestamp>.<raw body>`,
 * hex-encoded and prefixed with `sha256=`, matching the scheme popularized
 * by GitHub/Stripe/Shopify/Slack webhooks. Including the timestamp in the
 * signed payload lets receivers reject replayed requests.
 *
 * @param signingSecret The per-webhook secret configured at creation time
 * @param rawBody The exact request body that will be sent
 * @param timestamp Unix seconds; defaults to the current time (injectable for tests)
 */
export const buildSignatureHeaders = (
    signingSecret: string,
    rawBody: string,
    timestamp?: number
): Record<string, string> => {
    const ts = timestamp ?? Math.floor(Date.now() / 1000);
    const signature = createHmac("sha256", signingSecret).update(`${ts}.${rawBody}`).digest("hex");
    return {
        [WEBHOOK_SIGNATURE_HEADER]: `sha256=${signature}`,
        [WEBHOOK_TIMESTAMP_HEADER]: String(ts)
    };
};
