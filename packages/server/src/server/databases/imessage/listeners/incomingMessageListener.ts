import { Message } from "@server/databases/imessage/entity/Message";
import { MessageChangeListener } from "./messageChangeListener";
import { DBWhereItem } from "../types";
import { isNotEmpty } from "@server/helpers/utils";

export class IncomingMessageListener extends MessageChangeListener {
    async getEntries(after: Date, before: Date): Promise<void> {
        const where: DBWhereItem[] = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 0 }
            }
        ];

        // If we have a last row id, only get messages after that
        if (this.lastRowId !== 0) {
            where.push({
                statement: "message.ROWID > :rowId",
                args: { rowId: this.lastRowId }
            });
        }

        // Do not use the "after" parameter if we have a last row id
        // Offset 15 seconds to account for the "Apple" delay
        const entries = await this.repo.getMessages({
            after: this.lastRowId === 0 ? new Date(after.getTime() - 15000) : null,
            withChats: true,
            where
        });

        // The 0th entry should be the newest since we sort by DESC
        if (isNotEmpty(entries)) {
            this.lastRowId = entries[0].ROWID;
        }

        // Emit the new message
        entries.forEach(async (entry: Message) => {
            const event = this.processMessageEvent(entry);
            if (!event) return;

            // Emit the event
            super.emit(event, this.transformEntry(entry));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
