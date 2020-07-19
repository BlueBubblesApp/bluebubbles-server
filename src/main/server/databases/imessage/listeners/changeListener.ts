import { EventEmitter } from "events";
import { EventCache } from "@server/eventCache";

export abstract class ChangeListener extends EventEmitter {
    stopped: boolean;

    cache: EventCache;

    lastCheck: Date;

    lastPurge: Date;

    pollFrequency: number;

    constructor({ cache = new EventCache(), pollFrequency = 1000 }: { cache?: EventCache; pollFrequency?: number }) {
        super();

        this.cache = cache;
        this.stopped = false;
        this.pollFrequency = pollFrequency;
        this.lastCheck = new Date();
        this.lastPurge = new Date();
    }

    stop() {
        this.stopped = true;
        this.removeAllListeners();
    }

    checkCache() {
        const now = new Date();

        // Purge emitted messages every 30 minutes to save memory (or every 100 items)
        if (this.cache.size() > 100 || now.getTime() - this.lastPurge.getTime() > 1800000) {
            if (this.cache.size() > 0) {
                this.cache.purge();
            }

            this.lastPurge = new Date();
        }
    }

    start() {
        this.cache.purge();
        this.lastCheck = new Date();
        this.lastPurge = new Date();

        // Start checking
        this.checkForNewEntries();
    }

    async checkForNewEntries(): Promise<void> {
        if (this.stopped) return;

        // Store the date when we started checking
        const beforeCheck = new Date();

        // Check the cache and see if it needs to be purged
        this.checkCache();

        try {
            // We pass the last check because we don't want it to change
            // while we process asynchronously
            await this.getEntries(this.lastCheck);

            // Save the date for when we started checking
            this.lastCheck = beforeCheck;
        } catch (err) {
            super.emit("error", err);
        }

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

    abstract async getEntries(after: Date): Promise<void>;
}
