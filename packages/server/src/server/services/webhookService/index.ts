import axios from "axios";
import { Server } from "@server";
import { Loggable } from "@server/lib/logging/Loggable";

export type WebhookEvent = {
    type: string;
    data: any;
};

/**
 * Redact credential-bearing query parameters (password, guid) from a webhook
 * URL before writing it to a log. Clients commonly register webhook URLs that
 * embed the server password or a shared guid as a query string, so logging the
 * raw URL writes that secret to disk on every dispatch. Falls back to the
 * input unchanged if parsing fails.
 */
const redactWebhookUrl = (url: string): string => {
    try {
        const parsed = new URL(url);
        for (const key of ["password", "guid"]) {
            if (parsed.searchParams.has(key)) parsed.searchParams.set(key, "***");
        }
        return parsed.toString();
    } catch {
        return url;
    }
};

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
            const safeUrl = redactWebhookUrl(i.url);
            this.log.debug(`Dispatching event to webhook: ${safeUrl}`);

            // We don't need to await this
            this.sendPost(i.url, event).catch(ex => {
                this.log.debug(`Failed to dispatch "${event.type}" event to webhook: ${safeUrl}`);
                this.log.debug(`  -> Error: ${ex?.message ?? String(ex)}`);
                this.log.debug(`  -> Status Text: ${ex?.response?.statusText}`);
            });
        }
    }

    private async sendPost(url: string, event: WebhookEvent) {
        return await axios.post(url, event, { headers: { "Content-Type": "application/json" } });
    }
}
