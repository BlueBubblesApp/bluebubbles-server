import { Message } from "@server/databases/imessage/entity/Message";
import { MessageChangeListener } from "./messageChangeListener";
import { DBWhereItem } from "../types";
import { isNotEmpty } from "@server/helpers/utils";
import { isMinVentura } from "@server/env";

export class IncomingMessageListener extends MessageChangeListener {
    async getEntries(after: Date, before: Date | null): Promise<void> {
        const afterOffsetDate = new Date(after.getTime() - 15000);
        await this.emitNewMessages(afterOffsetDate);
        await this.emitUpdatedMessages(afterOffsetDate);
    }

    async emitNewMessages(after: Date) {
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
        entries.forEach(async (entry: Message) => {
            const event = this.processMessageEvent(entry);
            if (!event) return;

            // Emit the event
            super.emit(event, this.transformEntry(entry));
        });
    }

    async emitUpdatedMessages(after: Date) {
        // An incoming message is only updated if it was unsent or edited.
        // This functionality is only available on macOS Ventura and newer.
        // Exit early to prevent over processing.
        if (!isMinVentura) return;

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
        entries.forEach(async (entry: Message) => {
            // If there is no edited/retracted date, it's not an updated message.
            // We only care about edited/retracted messages.
            // The other dates are delivered, read, and played.
            // isEmpty is what is used instead of dateRetracted... Just Apple things...
            if (!entry.dateEdited && !entry.dateRetracted && !entry.isEmpty) return;

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
