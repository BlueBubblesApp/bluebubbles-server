import { Connection } from "typeorm";
import { EventCache } from "@server/eventCache";
import { Queue } from "@server/entity/Queue";
import { ChangeListener } from "@server/api/imessage/listeners/changeListener";
import { MessageRepository } from "@server/api/imessage";
import { Message } from "@server/api/imessage/entity/Message";


export class QueueService extends ChangeListener {
    db: Connection;

    repo: MessageRepository;

    frequencyMs: number;

    constructor(db: Connection, repo: MessageRepository, cache: EventCache, pollFrequency: number) {
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
            if (now - entry.dateCreated > (1000 * 60)) {
                await repo.remove(entry);
                super.emit("message-timeout", entry);
                return;
            }

            // Check if the entry exists in the messages DB
            const matches = await this.repo.getMessages({
                chatGuid: entry.chatGuid,
                limit: 1,
                withHandle: false,  // Exclude to speed up query
                after: new Date(entry.dateCreated),
                where: [
                    {
                        // Text must match
                        statement: "message.text = :text",
                        args: { text: entry.text }
                    },
                    {
                        // Text must be from yourself
                        statement: "message.is_from_me = :fromMe",
                        args: { fromMe: 1 }
                    }
                ]
            });

            // If we have matches, emit it and delete it from the Queue
            if (matches && matches.length > 0) {
                super.emit("message-match", {tempGuid: entry.tempGuid, message: matches[0]});
                await repo.remove(entry);
            }
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
