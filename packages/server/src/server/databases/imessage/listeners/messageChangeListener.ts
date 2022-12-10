import { EventEmitter } from "events";
import { EventCache } from "@server/eventCache";
import { Message } from "../entity/Message";

type MessageState = {
    dateCreated: number;
    dateDelivered: number;
    dateRead: number;
    dateEdited: number;
    dateRetracted: number;
};

export abstract class MessageChangeListener extends EventEmitter {
    stopped: boolean;

    // Cache of messages that have been "seen" by a listener
    cache: EventCache;

    // Cache of the last state of the message that has been seen by a listener
    cacheState: Record<string, MessageState>;

    lastCheck: Date;

    pollFrequency: number;

    constructor({ cache = new EventCache(), pollFrequency = 1000 }: { cache?: EventCache; pollFrequency?: number }) {
        super();

        this.cache = cache;
        this.cacheState = {};
        this.stopped = false;
        this.pollFrequency = pollFrequency;
        this.lastCheck = new Date();
    }

    stop() {
        this.stopped = true;
        this.removeAllListeners();
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
            dateRetracted: message.dateRetracted ? message.dateRetracted.getTime() : 0
        };

        return event;
    }

    start() {
        this.cache.purge();
        this.lastCheck = new Date();

        // Start checking
        this.checkForNewEntries();
    }

    async checkForNewEntries(): Promise<void> {
        if (this.stopped) return;

        // Store the date when we started checking
        const beforeCheck = new Date();

        try {
            // We pass the last check because we don't want it to change
            // while we process asynchronously
            await this.getEntries(this.lastCheck, beforeCheck);

            // Save the date for when we started checking
            this.lastCheck = beforeCheck;
        } catch (err) {
            super.emit("error", err);
        }

        // Check the cache and see if it needs to be purged
        this.checkCache();

        // If the time it took to do the checking is less than 1 second, find the difference
        const after = new Date();
        const processTime = after.getTime() - beforeCheck.getTime();
        let waitTime = this.pollFrequency;

        // If the processing time took less than the poll frequency, only wait out the remainder
        // If the processing time took more than the poll frequency, don't wait at all
        if (processTime < this.pollFrequency) waitTime = this.pollFrequency - processTime;
        if (processTime >= this.pollFrequency) waitTime = 0;

        // Re-run check emssages code
        setTimeout(() => this.checkForNewEntries(), waitTime);
    }

    abstract getEntries(after: Date, before: Date): Promise<void>;
}
