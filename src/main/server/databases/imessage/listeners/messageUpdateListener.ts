import { MessageRepository } from "@server/databases/imessage";
import { Message } from "@server/databases/imessage/entity/Message";
import { ChangeListener } from "./changeListener";

export class MessageUpdateListener extends ChangeListener {
    repo: MessageRepository;

    constructor(repo: MessageRepository, pollFrequency: number) {
        super({ pollFrequency });

        this.repo = repo;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date): Promise<void> {
        const offsetDate = new Date(after.getTime() - 5000);
        const entries = await this.repo.getUpdatedMessages({ after: offsetDate, withChats: true });

        // Emit the new message
        entries.forEach(async (entry: any) => {
            // Compile so it's unique based on dates as well as ROWID
            const delivered = entry.dateDelivered ? entry.dateDelivered.getTime() : 0;
            const read = entry.dateRead ? entry.dateRead.getTime() : 0;
            const compiled = `${entry.ROWID}:${delivered}:${read}`;

            // Skip over any that we've finished
            if (this.cache.find(compiled)) return;

            // Add to cache
            this.cache.add(compiled);

            // Send the built message object
            super.emit("updated-entry", this.transformEntry(entry));

            // Add artificial delay so we don't overwhelm any listeners
            await new Promise((resolve, _) => setTimeout(() => resolve(), 500));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
