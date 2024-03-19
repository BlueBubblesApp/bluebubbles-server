import { Server } from "@server";
import { DBWhereItem } from "@server/databases/imessage/types";
import { isNotEmpty } from "@server/helpers/utils";
import { isMinMonterey } from "@server/env";
import type { Message } from "../entity/Message";
import { IMessagePollResult, IMessagePoller } from ".";

export class OutgoingUpdatedMessagePoller extends IMessagePoller {
    notSent: number[] = [];

    /**
     * Gets sent entries from yourself. This method has a very different flow
     * from the other listeners. It needs to do a good amount more to be accurate.
     *
     * Flow:
     * 1. Check for any unsent messages (is_sent == 0) from you
     * 2. Check for any sent messages (is_sent == 1) from you
     * 3. Use the "notSent" list to check for any items that
     *    previously weren't sent, but have been sent now
     * 4. Add any unsent messages from step 1 to the "notSent" list
     * 5. Emit the newly sent messages + previously not sent messages from step 3
     * 6. Emit messages that have errored out
     *
     * @param after
     * @param before The time right before get Entries run
     */
    async poll(after: Date, before: Date | null): Promise<IMessagePollResult[]> {
        const afterOffsetDate = new Date(after.getTime() - 15000);
        return await this.getUpdatedMessages(afterOffsetDate);
    }

    async getUpdatedMessages(after: Date): Promise<IMessagePollResult[]> {
        const results: IMessagePollResult[] = [];

        // Get updated entries from myself only
        const entries = await this.repo.getUpdatedMessages({
            after,
            withChats: true,
            where: [
                {
                    statement: "message.is_from_me = :isFromMe",
                    args: { isFromMe: 1 }
                }
            ]
        });

        // Get entries that have an updated "didNotifyRecipient" value (true), only for Monterey+
        let notifiedEntries: Message[] = [];
        if (isMinMonterey) {
            [notifiedEntries] = await this.repo.getMessages({
                after,
                withChats: true,
                where: [
                    {
                        statement: "message.is_from_me = :isFromMe",
                        args: { isFromMe: 1 }
                    },
                    {
                        statement: "message.did_notify_recipient = :didNotifyRecipient",
                        args: { didNotifyRecipient: 1 }
                    }
                ]
            });
        }

        // Emit the new message
        for (const entry of [...entries, ...notifiedEntries]) {
            const event = this.processMessageEvent(entry);
            if (!event) continue;

            // Resolve the promise
            Server().messageManager.resolve(entry);

            // Emit it as a normal update
            results.push({ eventType: event, data: entry });
        }

        return results;
    }
}
