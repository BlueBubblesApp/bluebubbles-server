import fs from "fs";
import { EventCache } from "@server/eventCache";
import EventEmitter from "events";

export abstract class WatcherListener extends EventEmitter {
    stopped: boolean;

    filePath: string;

    cache: EventCache;

    constructor({ filePath, cache = new EventCache() }: { filePath: string, cache?: EventCache; }) {
        super();

        this.filePath = filePath;
        this.cache = cache;
        this.stopped = false;
    }

    checkCache() {
        // Purge emitted items if it gets above 250 items
        // 250 is pretty arbitrary at this point...
        if (this.cache.size() > 250) {
            if (this.cache.size() > 0) {
                this.cache.purge();
            }
        }
    }

    stop() {
        this.stopped = true;
        this.removeAllListeners();
    }

    start() {
        this.cache.purge();

        // Start checking
        this.checkForNewEntries();
    }

    async checkForNewEntries(): Promise<void> {
        if (this.stopped) return;

        fs.watchFile(this.filePath, async (_, prev) => {
            await this.getEntries(prev.mtime, null);
        });

        // Check the cache and see if it needs to be purged
        this.checkCache();
    }

    abstract getEntries(after: Date, before: Date | null): Promise<void>;
}
