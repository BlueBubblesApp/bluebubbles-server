import { Connection } from "typeorm";
import { EventCache } from "@server/eventCache";
import { Queue } from "@server/entity/Queue";
import { ChangeListener } from "@server/api/imessage/listeners/changeListener";
import { MessageRepository } from "@server/api/imessage";
import { Message } from "@server/api/imessage/entity/Message";
import { DBWhereItem } from "@server/api/imessage/types";

export class QueueService extends ChangeListener {
    db: Connection;

    repo: MessageRepository;

    frequencyMs: number;

    constructor(
        db: Connection,
        repo: MessageRepository,
        cache: EventCache,
        pollFrequency: number
    ) {
        super({ cache, pollFrequency });

        this.db = db;
        this.repo = repo;
        this.frequencyMs = pollFrequency;
    }

    async getEntries(after: Date): Promise<void> {
        const now = new Date().getTime();
        const repo = this.db.getRepository(Queue);

        // Get all queued items
        const entries = await repo.find();
        entries.forEach(async (entry: Queue) => {
            // If the entry has been in there for longer than 1 minute, delete it, and send a message-timeout
            if (now - entry.dateCreated > 1000 * 60) {
                await repo.remove(entry);
                super.emit("message-timeout", entry);
                return;
            }

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
            } else {
                where = [
                    ...where,
                    {
                        // Text must match
                        statement: "message.text = :text",
                        args: { text: entry.text }
                    }
                ];
            }

            // Check if the entry exists in the messages DB
            const matches = await this.repo.getMessages({
                chatGuid: entry.chatGuid,
                limit: 3, // Limit to 3 to get any edge cases (possibly when spamming)
                withHandle: false, // Exclude to speed up query
                after: new Date(entry.dateCreated),
                before: new Date(),
                sort: "ASC",
                where
            });

            matches.forEach(async (match) => {
                this.cache.add(match.guid);
                super.emit("message-match", {
                    tempGuid: entry.tempGuid,
                    message: match
                });
                await repo.remove(entry);
            });
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
