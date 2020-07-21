import { MessageRepository } from "@server/databases/imessage";
import { Message } from "@server/databases/imessage/entity/Message";
import { EventCache } from "@server/eventCache";
import { ChangeListener } from "./changeListener";
import { getCacheName } from "../helpers/utils";

export class IncomingMessageListener extends ChangeListener {
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
        const entries = await this.repo.getMessages({
            after: offsetDate,
            before,
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
            const cacheName = getCacheName(entry);

            // Skip over any that we've finished
            if (this.cache.find(cacheName)) return;

            // Add to cache
            this.cache.add(cacheName);
            super.emit("new-entry", this.transformEntry(entry));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
