import axios, { AxiosRequestConfig } from "axios";
import { Server } from "@server";
import { Loggable } from "@server/lib/logging/Loggable";
import { Webhook } from "@server/databases/server/entity";
import {
    guardedHttpAgent,
    guardedHttpsAgent,
    parseWebhookUrl,
    WebhookSecurityOptions
} from "./addressGuard";

export type WebhookEvent = {
    type: string;
    data: any;
};

const REQUEST_TIMEOUT_MS = 15000;
const MAX_REDIRECTS = 5;
const MAX_RESPONSE_BYTES = 1024 * 1024;

export const getWebhookSecurityOptions = (webhook: Webhook): WebhookSecurityOptions => ({
    blockPrivateAddresses: !!webhook.blockPrivateAddresses,
    requireHttps: !!webhook.requireHttps,
    followRedirects: !!webhook.followRedirects
});

/**
 * Handles dispatching webhooks
 */
export class WebhookService extends Loggable {
    tag = "WebhookService";

    async dispatch(event: WebhookEvent) {
        const webhooks = await Server().repo.getWebhooks();
        for (const i of webhooks) {
            const eventTypes = JSON.parse(i.events) as Array<string>;
            if (!eventTypes.includes("*") && !eventTypes.includes(event.type)) continue;
            this.log.debug(`Dispatching event to webhook: ${i.url}`);

            // We don't need to await this
            this.sendPost(i, event).catch(ex => {
                this.log.debug(`Failed to dispatch "${event.type}" event to webhook: ${i.url}`);
                this.log.debug(`  -> Error: ${ex?.message ?? String(ex)}`);
                this.log.debug(`  -> Status Text: ${ex?.response?.statusText}`);
            });
        }
    }

    private async sendPost(webhook: Webhook, event: WebhookEvent) {
        const options = getWebhookSecurityOptions(webhook);

        // Re-validate on every send against the row's own options. Rows that predate these options were migrated
        // with every option off, so for them this only enforces an http(s) scheme.
        const url = parseWebhookUrl(webhook.url, options);

        const config: AxiosRequestConfig = {
            headers: { "Content-Type": "application/json" },
            timeout: REQUEST_TIMEOUT_MS,
            maxContentLength: MAX_RESPONSE_BYTES,
            maxRedirects: options.followRedirects ? MAX_REDIRECTS : 0,
            beforeRedirect: (redirect: Record<string, any>) => {
                // Hold every redirect hop to the same rules as the original URL
                const target = redirect.href ?? `${redirect.protocol}//${redirect.host}${redirect.path ?? ""}`;
                parseWebhookUrl(target, options);
            }
        };

        if (options.blockPrivateAddresses) {
            // Connect only to addresses the guarded lookup approved, and never via an env-configured proxy
            config.proxy = false;
            config.httpAgent = guardedHttpAgent;
            config.httpsAgent = guardedHttpsAgent;
        }

        return await axios.post(url.href, event, config);
    }
}
