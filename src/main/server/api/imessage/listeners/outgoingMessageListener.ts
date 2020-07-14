import { MessageRepository } from "@server/api/imessage";
import { Message } from "@server/api/imessage/entity/Message";
import { EventCache } from "@server/eventCache";
import { ChangeListener } from "./changeListener";

export class OutgoingMessageListener extends ChangeListener {
    repo: MessageRepository;

    notSent: number[];

    constructor(repo: MessageRepository, cache: EventCache, pollFrequency: number) {
        super({ cache, pollFrequency });

        this.repo = repo;
        this.notSent = [];

        // Start the listener
        this.start();
    }

    /**
     * Gets sent entries from yourself. This method has a very different flow
     * from the other listeners. It needs to do a good amount more to be accurate.
     *
     * Flow:
     * 1. Check for any unsent messages (is_sent == 0) from you
     * 2. Check for any sent messages (is_sent == 1) from you
     * 3. Use the "notSent" list to check for any items that
     *    previously weren't sent, but have been sent now
     * 4. Add any unsent messages from step 1 to the "notSent" list
     * 5. Emit the newly sent messages + previously not sent messages from step 3
     * 6. Emit messages that have errored out
     *
     * @param after
     */
    async getEntries(after: Date): Promise<void> {
        const offsetDate = new Date(after.getTime() - 5000);
        const baseQuery = [
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
                args: { fromMe: 1 }
            }
        ];

        // First, check for unsent messages
        const newUnsent = await this.repo.getMessages({
            after: offsetDate,
            withChats: false,
            withAttachments: false,
            withHandle: false,
            where: [
                ...baseQuery,
                {
                    statement: "message.is_sent = :isSent",
                    args: { isSent: 0 }
                }
            ]
        });

        // Second, check for sent messages
        const newSent = await this.repo.getMessages({
            after: offsetDate,
            withChats: true,
            where: [
                ...baseQuery,
                {
                    statement: "message.is_sent = :isSent",
                    args: { isSent: 1 }
                }
            ]
        });

        // Make sure none of the "sent" ones include the unsent ones
        const unsent = [];
        for (const us of newUnsent) {
            let found = false;
            for (const s of newSent) {
                if (us.ROWID === s.ROWID) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                unsent.push(us.ROWID);
            }
        }

        // Third, check for anything that hasn't been sent
        const lookbackSent = await this.repo.getMessages({
            withChats: true,
            where: [
                ...baseQuery,
                {
                    statement: `message.ROWID in (${this.notSent.join(", ")})`,
                    args: null
                }
            ]
        });

        // Fourth, add the new unsent items to the list
        const sentOrErrored = lookbackSent.filter(item => item.isSent || item.error > 0).map(item => item.ROWID);
        this.notSent = this.notSent.filter(item => !sentOrErrored.includes(item)); // Filter down not sent
        for (const i of unsent) // Add newly unsent to
            if (!this.notSent.includes(i)) this.notSent.push(i);

        // Add 2 second artificial delay to help eliminate duplicates
        await new Promise((resolve, _) => setTimeout(() => resolve(), 3000));

        // Emit the sent messages
        const entries = [...newSent, ...lookbackSent.filter(item => item.isSent)];
        entries.forEach(async (entry: any) => {
            // Skip over any that we've finished
            if (this.cache.find(entry.guid)) return;

            // Add to cache
            this.cache.add(entry.guid);
            super.emit("new-entry", this.transformEntry(entry));
        });

        // Emit the errored messages
        const errored = lookbackSent.filter(item => item.error > 0);
        errored.forEach(async (entry: any) => {
            super.emit("message-send-error", this.transformEntry(entry));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
