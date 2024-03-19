import { convertDateTo2001Time } from "../helpers/dateUtil";
import { IMessagePollResult, IMessagePoller } from ".";

export class ChatUpdatePoller extends IMessagePoller {
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
    async poll(after: Date, before: Date): Promise<IMessagePollResult[]> {
        // Emit when a chat's read status changes
        const afterOffsetDate = new Date(after.getTime() - 15000);
        return await this.emitChatReadUpdates(afterOffsetDate);
    }

    async emitChatReadUpdates(after: Date): Promise<IMessagePollResult[]> {
        const results: IMessagePollResult[] = [];

        // 1: Check for updated chats
        const [updatedChats, _] = await this.repo.getChats({
            where: [
                {
                    statement: "chat.last_read_message_timestamp >= :after",
                    args: { after: convertDateTo2001Time(after) }
                }
            ]
        });

        // Emit all the chats that had a last message update
        for (const entry of updatedChats) {
            const event = this.processChatEvent(entry);
            if (!event) continue;

            // Emit it as normal entry
            results.push({ eventType: event, data: entry });
        }

        return results;
    }
}
