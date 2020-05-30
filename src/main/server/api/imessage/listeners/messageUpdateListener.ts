import { DatabaseRepository } from "@server/api/imessage";
import { Message } from "@server/api/imessage/entity/Message";
import { ChangeListener } from "./changeListener";

export class MessageUpdateListener extends ChangeListener {
    repo: DatabaseRepository;

    frequencyMs: number;

    constructor(repo: DatabaseRepository, pollFrequency: number) {
        super(pollFrequency);

        this.repo = repo;
        this.frequencyMs = pollFrequency;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date): Promise<void> {
        const offsetDate = new Date(after.getTime() - 5000);
        const entries = await this.repo.getUpdatedMessages({ after: offsetDate, withChats: true });

        // Emit the new message
        entries.forEach((entry: any) => {
            // Compile so it's unique based on dates as well as ROWID
            const delivered = entry.dateDelivered ? entry.dateDelivered.getTime() : 0;
            const read = entry.dateRead ? entry.dateRead.getTime() : 0;
            const compiled = `${entry.ROWID}:${delivered}:${read}`;

            // Skip over any that we've finished
            if (this.emittedItems.includes(compiled)) return;

            // Add to cache
            this.emittedItems.push(compiled);

            // Send the built message object
            super.emit("updated-entry", this.transformEntry(entry));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
