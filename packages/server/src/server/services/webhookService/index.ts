import * as process from "process";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import axios from "axios";
import { Server } from "@server";

export type WebhookEvent = {
    type: string;
    data: any;
}

/**
 * Handles dispatching webhooks
 */
export class WebhookService {
    
    async dispatch(event: WebhookEvent) {
        const webhooks = await Server().repo.getWebhooks();
        for (const i of webhooks) {
            const eventTypes = JSON.parse(i.events) as Array<string>;
            if (!eventTypes.includes('*') && !eventTypes.includes(event.type)) continue;
            Server().log(`Dispatching event to webhook: ${i.url}`, 'debug');

            // We don't need to await this
            this.sendPost(i.url, event).catch((ex) => {
                Server().log(`Failed to dispatch event to webhook: ${i.url}`, 'warn');
                Server().log(ex?.message ?? String(ex), 'debug');
            });
        }
    }

    private async sendPost(url: string, event: WebhookEvent) {
        return await axios.post(url, event, { headers: { 'Content-Type': 'application/json' } });
    }
}
