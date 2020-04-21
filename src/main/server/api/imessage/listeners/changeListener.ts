import { EventEmitter } from "events";
import { convertDateTo2001Time } from "@server/api/imessage/helpers/dateUtil";

export abstract class ChangeListener extends EventEmitter {
    stopped: boolean;

    emittedItems: string[];

    lastCheck: Date;

    lastPurge: Date;

    pollFrequency: number;

    constructor(pollFrequency = 1000) {
        super();

        this.stopped = false;
        this.pollFrequency = pollFrequency;
        this.lastCheck = new Date();
        this.lastPurge = new Date();
    }

    stop() {
        this.stopped = true;
    }

    purgeCache() {
        const now = new Date();

        // Purge emitted messages every 30 minutes to save memory
        if (now.getTime() - this.lastPurge.getTime() > 1800000) {
            if (this.emittedItems.length > 0) {
                console.info(
                    `Purging ${this.emittedItems.length} emitted messages from cahche...`
                );
                this.emittedItems = [];
            }

            this.lastPurge = new Date();
        }
    }

    async start(): Promise<null> {
        this.emittedItems = [];
        this.lastCheck = new Date();
        this.lastPurge = new Date();

        // Start checking
        this.checkForNewEntries();

        // So ESLint won't yell at us
        return null;
    }

    async checkForNewEntries(): Promise<void> {
        if (this.stopped) return;

        // Check the cache and see if it needs to be purged
        this.purgeCache();

        try {
            const beforeCheck = new Date();
            await this.getEntries();
            this.lastCheck = beforeCheck;
        } catch (err) {
            this.stopped = true;
            super.emit("error", err);
        }

        // Re-run check emssages code
        setTimeout(() => this.checkForNewEntries(), this.pollFrequency);
    }

    abstract getEntries(): void;

    abstract transformEntry(entry: any): any;
}
