import axios from "axios";
import { Server } from "@server";
import { Loggable } from "@server/lib/logging/Loggable";
import { buildSignatureHeaders } from "./signing";

export type WebhookEvent = {
    type: string;
    data: any;
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
            this.log.debug(`Dispatching event to webhook: ${i.url}`);

            // We don't need to await this
            this.sendPost(i.url, event, i.signing_secret).catch(ex => {
                this.log.debug(`Failed to dispatch "${event.type}" event to webhook: ${i.url}`);
                this.log.debug(`  -> Error: ${ex?.message ?? String(ex)}`);
                this.log.debug(`  -> Status Text: ${ex?.response?.statusText}`);
            });
        }
    }

    private async sendPost(url: string, event: WebhookEvent, signingSecret?: string | null) {
        // Serialize the payload ourselves so that the signature (if any)
        // is computed over the exact bytes that are sent.
        const body = JSON.stringify(event);
        const headers: Record<string, string> = { "Content-Type": "application/json" };
        if (signingSecret) {
            Object.assign(headers, buildSignatureHeaders(signingSecret, body));
        }

        return await axios.post(url, body, { headers });
    }
}
