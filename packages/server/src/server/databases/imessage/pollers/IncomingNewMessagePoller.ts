import { Message } from "@server/databases/imessage/entity/Message";
import { DBWhereItem } from "../types";
import { IMessagePollResult, IMessagePoller } from ".";


export class IncomingNewMessagePoller extends IMessagePoller {
    async poll(after: Date, before: Date | null): Promise<IMessagePollResult[]> {
        const afterOffsetDate = new Date(after.getTime() - 15000);
        return await this.getNewMessages(afterOffsetDate);
    }

    async getNewMessages(after: Date): Promise<IMessagePollResult[]> {
        const results: IMessagePollResult[] = [];
        const where: DBWhereItem[] = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 0 }
            }
        ];

        // Do not use the "after" parameter if we have a last row id
        // Offset 15 seconds to account for the "Apple" delay
        const [entries, _] = await this.repo.getMessages({
            after,
            withChats: true,
            where,
            orderBy: "message.dateCreated"
        });

        // Emit the new message
        for (const entry of entries) {
            const event = this.processMessageEvent(entry);
            if (!event) continue;

            // Emit the event
            results.push({ eventType: event, data: entry });
        }

        return results;
    }
}
