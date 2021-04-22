import { Server } from "@server/index";
import { MessageRepository } from "@server/databases/imessage";
import { EventCache } from "@server/eventCache";
import { getCacheName } from "@server/databases/imessage/helpers/utils";
import { DBWhereItem } from "@server/databases/imessage/types";
import { onlyAlphaNumeric } from "@server/helpers/utils";
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
    async getEntries(after: Date, before: Date): Promise<void> {
        // First, emit message matches
        await this.emitMessageMatches();

        // Second, emit the outgoing messages (lookback 15 seconds to make up for the "Apple" delay)
        await this.emitOutgoingMessages(new Date(after.getTime() - 15000), before);

        // Third, check for updated messages
        await this.emitUpdatedMessages(new Date(after.getTime() - this.pollFrequency), before);
    }

    async emitMessageMatches(): Promise<void> {
        const now = new Date().getTime();
        const repo = Server().db.queue();

        // Get all queued items
        const entries = await repo.find();
        if (entries.length > 0) {
            Server().log(`Detected ${entries.length} queued outgoing message(s)`, "debug");
        }

        for (const entry of entries) {
            // If the entry has been in there for longer than 1 minute, delete it, and send a message-timeout
            if (now - entry.dateCreated > 1000 * 60) {
                await repo.remove(entry);
                super.emit("message-timeout", entry);
                continue;
            }

            // The "default" where clause. Just stuff from ourselves
            let where: DBWhereItem[] = [
                {
                    // Text must be from yourself
                    statement: "message.is_from_me = :fromMe",
                    args: { fromMe: 1 }
                }
            ];

            // If the text starts with the temp GUID, we know it's an attachment
            // See /server/helpers/action.ts -> sendMessage()
            // Since it's an attachment, we want to change some of the parameters
            if (entry.text.startsWith(entry.tempGuid)) {
                where = [
                    ...where,
                    {
                        // Text must be empty if it's an attachment
                        statement: "length(message.text) = 1",
                        args: null
                    },
                    {
                        // The attachment name must match what we've saved in the text
                        statement: "attachment.transfer_name = :name",
                        args: { name: entry.text.split("->")[1] }
                    }
                ];
            }

            // Check for any message created after the "date created" of the queue item
            // We will (re)emit all messages. The cache should catch if any dupes are being sent
            let matches = await Server().iMessageRepo.getMessages({
                chatGuid: entry.chatGuid,
                limit: 25, // 25 is semi-arbitrary. We just don't want to miss anything
                withHandle: false, // Exclude to speed up query
                after: new Date(entry.dateCreated),
                sort: "ASC", // Ascending because we want to send the newest first
                where
            });

            // Filter down the results to only that match the sanitized value
            // Only if it's a message, not an attachment
            if (!entry.text.startsWith(entry.tempGuid)) {
                matches = matches.filter(msg => onlyAlphaNumeric(entry.text) === onlyAlphaNumeric(msg.text));
            }

            // Find the first non-emitted match
            for (const match of matches) {
                const matchGuid = `match:${match.guid}`;

                // If we've already emitted this message-match, skip it
                if (this.cache.find(matchGuid)) continue;

                // Emit the message match to listeners
                super.emit("message-match", { tempGuid: entry.tempGuid, message: match });

                // Add the message to the cache
                const cacheName = getCacheName(match);
                this.cache.add(cacheName);

                // We add twice because the message match cache name is slightly different than the standard one
                // The message match cache is only "relative" to the message match method as opposed to the global one
                this.cache.add(matchGuid);

                // Remove the queue entry from the database
                if (matches.length > 0) await repo.remove(entry);

                // Break because we only want one
                break;
            }
        }
    }

    async emitOutgoingMessages(after: Date, before: Date) {
        const baseQuery = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 1 }
            }
        ];

        // If SMS support is disabled, only search for iMessage
        const smsSupport = Server().db.getConfig("sms_support") as boolean;
        if (!smsSupport) {
            baseQuery.push({
                statement: "message.service = 'iMessage'",
                args: null
            });
        }

        // First, check for unsent messages
        const newUnsent = await this.repo.getMessages({
            after,
            before,
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

        if (newUnsent.length > 0) {
            Server().log(`Detected ${newUnsent.length} unsent outgoing message(s)`, "debug");
        }

        // Second, check for sent messages
        const newSent = await this.repo.getMessages({
            after,
            before,
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

        if (lookbackSent.length > 0) {
            Server().log(`Detected ${lookbackSent.length} sent (previously unsent) message(s)`, "debug");
        }

        // Fourth, add the new unsent items to the list
        const sentOrErrored = lookbackSent.filter(item => item.isSent || item.error > 0).map(item => item.ROWID);
        this.notSent = this.notSent.filter(item => !sentOrErrored.includes(item)); // Filter down not sent
        for (const i of unsent) // Add newly unsent to
            if (!this.notSent.includes(i)) this.notSent.push(i);

        // Emit the sent messages
        const entries = [...newSent, ...lookbackSent.filter(item => item.isSent)];
        for (const entry of entries) {
            const cacheName = getCacheName(entry);

            // Skip over any that we've finished
            if (this.cache.find(cacheName)) return;

            // Add to cache
            this.cache.add(cacheName);
            super.emit("new-entry", entry);
        }

        // Emit the errored messages
        const errored = lookbackSent.filter(item => item.error > 0);
        for (const entry of errored) super.emit("message-send-error", entry);
    }

    async emitUpdatedMessages(after: Date, before: Date) {
        const baseQuery: DBWhereItem[] = [];

        // If SMS support is disabled, only search for iMessage
        const smsSupport = Server().db.getConfig("sms_support") as boolean;
        if (!smsSupport) {
            baseQuery.push({
                statement: "message.service = 'iMessage'",
                args: null
            });
        }

        // Get updated entries from myself only
        const entries = await this.repo.getUpdatedMessages({
            after,
            before,
            withChats: true,
            where: [
                ...baseQuery,
                {
                    statement: "message.is_from_me = :isFromMe",
                    args: { isFromMe: 1 }
                }
            ]
        });

        if (entries.length > 0) {
            Server().log(`Detected ${entries.length} updated message(s)`, "debug");
        }

        // Emit the new message
        for (const entry of entries) {
            // Compile so it's unique based on dates as well as ROWID
            const cacheName = getCacheName(entry);

            // Skip over any that we've finished
            if (this.cache.find(cacheName)) return;

            // Add to cache
            this.cache.add(cacheName);

            // Send the built message object
            super.emit("updated-entry", entry);

            // Add artificial delay so we don't overwhelm any listeners
            await new Promise<void>((resolve, _) => setTimeout(() => resolve(), 200));
        }
    }
}
