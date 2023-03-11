import { EventCache } from "@server/eventCache";
import { MessageRepository } from "..";
import { Message } from "../entity/Message";
import { ChangeListener } from "./changeListener";
import { isEmpty } from "@server/helpers/utils";

type MessageState = {
    dateCreated: number;
    dateDelivered: number;
    dateRead: number;
    dateEdited: number;
    dateRetracted: number;
    didNotifyRecipient: boolean;
};

export abstract class MessageChangeListener extends ChangeListener {
    // Cache of the last state of the message that has been seen by a listener
    cacheState: Record<string, MessageState> = {};

    lastRowId = 0;

    repo: MessageRepository;

    constructor(repo: MessageRepository, cache: EventCache, pollFrequency: number) {
        super({ cache, pollFrequency });

        this.repo = repo;
        this.getLastRowId().then((rowId: number) => {
            // Don't set it if we've already got a last row ID or the return was already 0
            if (this.lastRowId > 0 || !rowId || rowId === 0) return;
            this.lastRowId = rowId;
        });
    }

    async getLastRowId(): Promise<number> {
        const [messages, _] = await this.repo.getMessages({ limit: 1, sort: "DESC" });
        if (isEmpty(messages)) return 0;
        return messages[0]?.ROWID ?? 0;
    }

    checkCache() {
        // Purge emitted messages if it gets above 250 items
        // 250 is pretty arbitrary at this point...
        if (this.cache.size() > 250) {
            if (this.cache.size() > 0) {
                this.cache.purge();
            }
        }

        // Purge anything from the cache where the date created is > 5 minutes old
        const now = new Date().getTime();
        const fiveMinutesAgo = now - 5 * 60 * 1000;
        for (const key in this.cacheState) {
            if (this.cacheState[key].dateCreated < fiveMinutesAgo) {
                delete this.cacheState[key];
            }
        }
    }

    getMessageEvent(message: Message): string | null {
        // If the GUID doesn't exist, it's a new message
        const guid = message.guid;
        if (!this.cache.find(guid)) return "new-entry";

        // If the GUID exists, check the date created.
        // If it doesn't exist, a race condition occurred and we should ignore it (return null)
        const state = this.cacheState[guid];
        if (!state) return null;

        // If any of the dates are newer, it's an update
        if (message.dateCreated.getTime() > state.dateCreated) return "updated-entry";

        const delivered = message?.dateDelivered ? message.dateDelivered.getTime() : 0;
        if (delivered > state.dateDelivered) return "updated-entry";

        const read = message?.dateRead ? message.dateRead.getTime() : 0;
        if (read > state.dateRead) return "updated-entry";

        const edited = message?.dateEdited ? message.dateEdited.getTime() : 0;
        if (edited > state.dateEdited) return "updated-entry";

        const retracted = message?.dateRetracted ? message.dateRetracted.getTime() : 0;
        if (retracted > state.dateRetracted) return "updated-entry";

        // If the "notified" state changed, it's an update
        const didNotify = message.didNotifyRecipient ?? false;
        if (didNotify !== state.didNotifyRecipient) return "updated-entry";

        return null;
    }

    processMessageEvent(message: Message): string | null {
        const event = this.getMessageEvent(message);
        if (!event) return null;

        if (event === "new-entry") {
            this.cache.add(message.guid);
        }

        this.cacheState[message.guid] = {
            dateCreated: message.dateCreated.getTime(),
            dateDelivered: message?.dateDelivered ? message.dateDelivered.getTime() : 0,
            dateRead: message?.dateRead ? message.dateRead.getTime() : 0,
            dateEdited: message.dateEdited ? message.dateEdited.getTime() : 0,
            dateRetracted: message.dateRetracted ? message.dateRetracted.getTime() : 0,
            didNotifyRecipient: message.didNotifyRecipient ?? false
        };

        return event;
    }
}
