import { MessageRepository } from "@server/api/imessage";
import { Message } from "@server/api/imessage/entity/Message";
import { EventCache } from "@server/eventCache";
import { ChangeListener } from "./changeListener";


export class MessageListener extends ChangeListener {
    repo: MessageRepository;

    constructor(repo: MessageRepository, cache: EventCache, pollFrequency: number) {
        super({ cache, pollFrequency });

        this.repo = repo;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date): Promise<void> {
        const offsetDate = new Date(after.getTime() - 5000);
        const entries = await this.repo.getMessages({ after: offsetDate, withChats: true });

        // Emit the new message
        entries.forEach(async (entry: any) => {
            // If from me, wait 3 seconds before doing anything so spam doesn't
            // cause duplicates
            if (entry.isFromMe)
                await new Promise((resolve, _) => setTimeout(() => resolve(), 3000));

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
