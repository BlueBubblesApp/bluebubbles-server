import { EventCache } from "@server/eventCache";
import { MultiFileWatcher } from "@server/lib/MultiFileWatcher";
import { Loggable } from "@server/lib/logging/Loggable";
import { Sema } from "async-sema";

export abstract class WatcherListener extends Loggable {
    tag = "WatcherListener";

    stopped: boolean;

    filePaths: string[];

    cache: EventCache;

    watcher: MultiFileWatcher;

    constructor({ filePaths, cache = new EventCache() }: { filePaths: string[]; cache?: EventCache }) {
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

        let lastCheck: number = new Date().getTime();
        this.watcher = new MultiFileWatcher(this.filePaths);

        const lock = new Sema(1);
        this.watcher.on("change", async event => {
            await lock.acquire();

            // If we don't have a prevStat, it's a new file, and we still need to get entries.
            // If the prevStat is newer than the last check, we need to check.
            this.log.debug(`Comparing ${event.prevStat?.mtimeMs} to ${lastCheck}`);
            if (!event.prevStat || event.prevStat.mtimeMs > lastCheck) {
                const after = event.prevStat?.mtimeMs ?? lastCheck;
                this.log.debug(`Checking for new entries after ${after}`);
                await this.getEntries(new Date(after), null);
                this.checkCache();

                this.log.debug(`Setting last check to ${after}`);
                lastCheck = after;
            } else {
                this.log.debug(`Event already handled!`);
            }

            // Release the lock
            lock.release();
        });

        this.watcher.start();
    }

    abstract getEntries(after: Date, before: Date | null): Promise<void>;
}
