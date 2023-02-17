import { Server } from "@server";
import { MessageRepository } from "@server/databases/imessage";
import { EventCache } from "@server/eventCache";
import { DBWhereItem } from "@server/databases/imessage/types";
import { isNotEmpty } from "@server/helpers/utils";
import { MessageChangeListener } from "./messageChangeListener";

export class OutgoingMessageListener extends MessageChangeListener {
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
     * @param before The time right before get Entries run
     */
    async getEntries(after: Date, before: Date): Promise<void> {
        // First, emit the outgoing messages (lookback 15 seconds to make up for the "Apple" delay)
        const afterOffsetDate = new Date(after.getTime() - 15000);
        await this.emitOutgoingMessages(afterOffsetDate);

        // Second, check for updated messages
        const afterUpdateOffsetDate = new Date(after.getTime() - this.pollFrequency - 15000);
        await this.emitUpdatedMessages(afterUpdateOffsetDate);
    }

    async emitOutgoingMessages(after: Date) {
        const baseQuery = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 1 }
            }
        ];

        // 1: Check for new messages
        const newMessages = await this.repo.getMessages({
            after,
            withChats: true,
            where: [...baseQuery]
        });

        // 2: Divide the new messages into sent/unsent buckets
        const newUnsent = newMessages.filter(e => !e.isSent);
        const newSent = newMessages.filter(e => e.isSent);
        if (isNotEmpty(newUnsent)) {
            Server().log(`Detected ${newUnsent.length} unsent outgoing message(s)`, "debug");
        }

        // 3: Gather IDs of all unsent messages (from now & previously)
        const unsentIds: number[] = newUnsent.map(e => e.ROWID);
        for (const i of this.notSent) {
            if (!unsentIds.includes(i)) unsentIds.push(i);
        }

        // 4: Find all unsent messages
        let lookbackMessages: any[] = [];
        if (isNotEmpty(unsentIds)) {
            lookbackMessages = await this.repo.getMessages({
                withChats: true,
                where: [
                    ...baseQuery,
                    {
                        statement: `message.ROWID in (${unsentIds.join(", ")})`,
                        args: null
                    }
                ]
            });
        }

        if (isNotEmpty(lookbackMessages)) {
            Server().log(`Detected ${lookbackMessages.length} sent (previously unsent) message(s)`, "debug");
        }

        // 5: Gather all the lookback messages and put them into buckets for the different outcomes
        const lookbackSent = lookbackMessages.filter(item => item.isSent && (item?.error ?? 0) === 0);
        const lookbackErrored = lookbackMessages.filter(item => (item?.error ?? 0) > 0);
        const lookbackUnsent = lookbackMessages.filter(item => !item.isSent && (item?.error ?? 0) === 0);

        // Update the global list containing messages that are still unsent
        this.notSent = lookbackUnsent.map(e => e.ROWID);

        // 6: Emit all the messages that were successfully sent
        for (const entry of [...newSent, ...lookbackSent]) {
            const event = this.processMessageEvent(entry);
            if (!event) return;

            // Resolve the promise for sent messages from a client
            Server().messageManager.resolve(entry);

            // Emit it as normal entry
            super.emit(event, entry);
        }

        // 6: Emit all the messages that failed sent
        for (const entry of lookbackErrored) {
            const event = this.processMessageEvent(entry);
            if (!event) return;

            // Reject the corresponding promise.
            // This will emit a message send error
            const success = await Server().messageManager.reject("message-send-error", entry);
            Server().log(
                `Errored Msg -> ${entry.guid} -> ${entry.contentString()} -> ${success} (Code: ${entry.error})`,
                "debug"
            );

            // Emit it as normal error
            if (!success) {
                Server().log(
                    `Message Manager Match Failed -> Promises: ${Server().messageManager.promises.length}`,
                    "debug"
                );
                super.emit("message-send-error", entry);
            }
        }
    }

    async emitUpdatedMessages(after: Date) {
        const baseQuery: DBWhereItem[] = [];

        // Get updated entries from myself only
        const entries = await this.repo.getUpdatedMessages({
            after,
            withChats: true,
            where: [
                ...baseQuery,
                {
                    statement: "message.is_from_me = :isFromMe",
                    args: { isFromMe: 1 }
                }
            ]
        });

        // Emit the new message
        for (const entry of entries) {
            const event = this.processMessageEvent(entry);
            if (!event) return;

            // Resolve the promise
            Server().messageManager.resolve(entry);

            // Emit it as a normal update
            super.emit(event, entry);
        }
    }
}
