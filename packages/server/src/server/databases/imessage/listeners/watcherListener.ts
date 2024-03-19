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

    processLock: Sema;

    constructor({ filePaths, cache = new EventCache() }: { filePaths: string[]; cache?: EventCache }) {
        super();

        this.filePaths = filePaths;
        this.cache = cache;
        this.stopped = false;
        this.processLock = new Sema(1);
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

        let lastCheck = 0;
        this.watcher = new MultiFileWatcher(this.filePaths);
        this.watcher.on("change", async event => {
            await this.processLock.acquire();

            // If we don't have a prevStat, it's a new file, and we still need to get entries.
            // If the prevStat is newer than the last check, we need to check.
            if (!event.prevStat || event.prevStat.mtimeMs > lastCheck) {
                // If we don't have a prevStat, we should use the currentStat's mtimeMs - 1 minute
                const after = event.prevStat?.mtimeMs ?? event.currentStat.mtimeMs - 60000;
                await this.getEntries(new Date(after), null);
                this.checkCache();
                lastCheck = after;
            }

            this.processLock.release();
        });

        this.watcher.on("error", (error) => {
            this.log.error(`Failed to watch database files: ${this.filePaths.join(", ")}`);
            this.log.debug(`Error: ${error}`);
        });

        this.watcher.start();
    }

    abstract getEntries(after: Date, before: Date | null): Promise<void>;
}
