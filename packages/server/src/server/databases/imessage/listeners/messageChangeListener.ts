import { EventCache } from "@server/eventCache";
import { MessageRepository } from "..";
import { Message } from "../entity/Message";
import { WatcherListener } from "./watcherListener";

type MessageState = {
    dateCreated: number;
    dateDelivered: number;
    dateRead: number;
    dateEdited: number;
    dateRetracted: number;
    didNotifyRecipient: boolean;
};

export abstract class MessageChangeListener extends WatcherListener {
    // Cache of the last state of the message that has been seen by a listener
    cacheState: Record<string, MessageState> = {};

    repo: MessageRepository;

    constructor(repo: MessageRepository, cache: EventCache) {
        super({
            filePath: repo.dbPathWal,
            cache
        });

        this.repo = repo;
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
