import fs from "fs";
import EventEmitter from "events";

import { EventCache } from "@server/eventCache";
import { MultiFileWatcher } from "@server/lib/MultiFileWatcher";


export abstract class WatcherListener extends EventEmitter {
    stopped: boolean;

    filePaths: string[];

    cache: EventCache;

    watcher: MultiFileWatcher;

    constructor({ filePaths, cache = new EventCache() }: { filePaths: string[], cache?: EventCache; }) {
        super();

        this.filePaths = filePaths;
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

        const now = new Date();
        this.watcher = new MultiFileWatcher(this.filePaths, async (event) => {
            await this.getEntries(event.prevStat?.mtime ?? now, null);
            this.checkCache();
        })
    }

    abstract getEntries(after: Date, before: Date | null): Promise<void>;
}
