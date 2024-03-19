import { IMessagePollResult, IMessagePoller } from ".";

export class GroupChangePoller extends IMessagePoller {
    async poll(after: Date, _: Date | null): Promise<IMessagePollResult[]> {
        const results: IMessagePollResult[] = [];
        const offsetDate = new Date(after.getTime() - 5000);
        const [entries, __] = await this.repo.getMessages({
            after: offsetDate,
            withChats: true,
            where: [
                {
                    statement: "message.text IS NULL",
                    args: null
                },
                {
                    statement: "message.item_type IN (1, 2, 3)",
                    args: null
                }
            ]
        });

        // Emit the new message
        for (const entry of entries) {
            const identifier = `group-change-${entry.ROWID}`;

            // Skip over any that we've finished
            if (this.cache.events.find(identifier)) continue;

            // Add to cache
            this.cache.events.add(identifier);

            // Send the built message object
            if (entry.itemType === 1 && entry.groupActionType === 0) {
                results.push({ eventType: "participant-added", data: entry });
            } else if (entry.itemType === 1 && entry.groupActionType === 1) {
                results.push({ eventType: "participant-removed", data: entry });
            } else if (entry.itemType === 2) {
                results.push({ eventType: "name-change", data: entry });
            } else if (entry.itemType === 3 && entry.groupActionType === 0) {
                results.push({ eventType: "participant-left", data: entry });
            } else if (entry.itemType === 3 && entry.groupActionType === 1) {
                results.push({ eventType: "group-icon-changed", data: entry });
            } else if (entry.itemType === 3 && entry.groupActionType === 2) {
                results.push({ eventType: "group-icon-removed", data: entry });
            } else {
                console.warn(`Unhandled message item type: [${entry.itemType}]`);
            }
        }

        return results;
    }
}
