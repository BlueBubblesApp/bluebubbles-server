import axios from "axios";
import { Server } from "@server";
import { Loggable } from "@server/lib/logging/Loggable";

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
        const eventChatGuids = this.extractChatGuids(event.data);

        for (const i of webhooks) {
            const eventTypes = JSON.parse(i.events) as Array<string>;
            if (!eventTypes.includes("*") && !eventTypes.includes(event.type)) continue;

            // Filter by chat GUIDs if the webhook has a chat filter configured
            const webhookChatGuids = i.chatGuids ? JSON.parse(i.chatGuids) as Array<string> : null;
            if (webhookChatGuids && webhookChatGuids.length > 0) {
                // Global/system events (no chat context) are always delivered to all webhooks
                if (eventChatGuids && !eventChatGuids.some(guid => webhookChatGuids.includes(guid))) {
                    continue;
                }
            }

            this.log.debug(`Dispatching event to webhook: ${i.url}`);

            // We don't need to await this
            this.sendPost(i.url, event).catch(ex => {
                this.log.debug(`Failed to dispatch "${event.type}" event to webhook: ${i.url}`);
                this.log.debug(`  -> Error: ${ex?.message ?? String(ex)}`);
                this.log.debug(`  -> Status Text: ${ex?.response?.statusText}`);
            });
        }
    }

    /**
     * Extracts chat GUIDs from event data.
     * Returns the list of chat GUIDs found, or null if the event has no chat context.
     *
     * Different event types store the chat GUID in different locations:
     * - Most message/group events: data.chats[].guid
     * - chat-read-status-changed: data.chatGuid
     * - typing-indicator: data.guid (contains semicolons like "iMessage;-;+15551234567")
     * - Global events (server-update, new-server, etc.): no chat context
     */
    private extractChatGuids(data: any): string[] | null {
        // Most message/group events include a chats array with guid fields
        if (data?.chats && Array.isArray(data.chats)) {
            const guids = data.chats.map((c: any) => c.guid).filter(Boolean);
            if (guids.length > 0) return guids;
        }

        // chat-read-status-changed uses a top-level chatGuid field
        if (data?.chatGuid && typeof data.chatGuid === "string") {
            return [data.chatGuid];
        }

        // typing-indicator uses a top-level guid that is a chat GUID (contains semicolons)
        if (data?.guid && typeof data.guid === "string" && data.guid.includes(";")) {
            return [data.guid];
        }

        // No chat context — this is a global/system event
        return null;
    }

    private async sendPost(url: string, event: WebhookEvent) {
        return await axios.post(url, event, { headers: { "Content-Type": "application/json" } });
    }
}
