import { MessageRepository } from "@server/databases/imessage";
import { Message } from "@server/databases/imessage/entity/Message";
import { EventCache } from "@server/eventCache";
import { MessageChangeListener } from "./messageChangeListener";

export class IncomingMessageListener extends MessageChangeListener {
    repo: MessageRepository;

    constructor(repo: MessageRepository, cache: EventCache, pollFrequency: number) {
        super({ cache, pollFrequency });

        this.repo = repo;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date, before: Date): Promise<void> {
        // Offset 15 seconds to account for the "Apple" delay
        const offsetDate = new Date(after.getTime() - 15000);
        const query = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 0 }
            }
        ];

        const entries = await this.repo.getMessages({
            after: offsetDate,
            withChats: true,
            where: query
        });

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
