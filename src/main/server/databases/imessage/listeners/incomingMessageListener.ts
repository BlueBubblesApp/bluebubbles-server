import { MessageRepository } from "@server/databases/imessage";
import { Message } from "@server/databases/imessage/entity/Message";
import { EventCache } from "@server/eventCache";
import { ChangeListener } from "./changeListener";

export class IncomingMessageListener extends ChangeListener {
    repo: MessageRepository;

    constructor(repo: MessageRepository, cache: EventCache, pollFrequency: number) {
        super({ cache, pollFrequency });

        this.repo = repo;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date): Promise<void> {
        const offsetDate = new Date(after.getTime() - 5000);
        const entries = await this.repo.getMessages({
            after: offsetDate,
            withChats: true,
            where: [
                {
                    statement: "message.service = 'iMessage'",
                    args: null
                },
                {
                    statement: "message.text IS NOT NULL",
                    args: null
                },
                {
                    statement: "message.is_from_me = :fromMe",
                    args: { fromMe: 0 }
                }
            ]
        });

        // Emit the new message
        entries.forEach(async (entry: any) => {
            // Skip over any that we've finished
            if (this.cache.find(entry.guid)) return;

            // Add to cache
            this.cache.add(entry.guid);
            super.emit("new-entry", this.transformEntry(entry));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
