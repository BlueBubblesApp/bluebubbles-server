import { Message } from "@server/databases/imessage/entity/Message";
import { DBWhereItem } from "../types";
import { isMinVentura } from "@server/env";
import { IMessagePollResult, IMessagePoller } from ".";


export class IncomingUpdatedMessagPoller extends IMessagePoller {
    async poll(after: Date, before: Date | null): Promise<IMessagePollResult[]> {
        const afterOffsetDate = new Date(after.getTime() - 15000);
        return await this.getUpdatedMessages(afterOffsetDate);
    }

    async getUpdatedMessages(after: Date): Promise<IMessagePollResult[]> {
        const results: IMessagePollResult[] = [];

        // An incoming message is only updated if it was unsent or edited.
        // This functionality is only available on macOS Ventura and newer.
        // Exit early to prevent over processing.
        if (!isMinVentura) return [];

        const where: DBWhereItem[] = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 0 }
            }
        ];

        // Do not use the "after" parameter if we have a last row id
        // Offset 15 seconds to account for the "Apple" delay
        const entries = await this.repo.getUpdatedMessages({
            after,
            withChats: true,
            where,
            orderBy: "message.dateCreated"
        });

        // Emit the new message
        for (const entry of entries) {
            // If there is no edited/retracted date, it's not an updated message.
            // We only care about edited/retracted messages.
            // The other dates are delivered, read, and played.
            // isEmpty is what is used instead of dateRetracted... Just Apple things...
            if (!entry.dateEdited && !entry.dateRetracted && !entry.isEmpty) continue;

            const event = this.processMessageEvent(entry);
            if (!event) continue;

            // Emit the event
            results.push({ eventType: event, data: entry });
        }

        return results;
    }
}
