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
            // If from me, wait 1 second before doing anything
            if (entry.isFromMe)
                await new Promise((resolve, _) => setTimeout(() => resolve(), 1000));

            // Skip over any that we've finished
            if (this.cache.find(entry.guid)) return;

            console.log("new-entry for:")
            console.log(entry.guid);

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
