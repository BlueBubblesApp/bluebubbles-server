import { EventCache } from "@server/eventCache";
import { MultiFileWatcher } from "@server/lib/MultiFileWatcher";
import { Loggable } from "@server/lib/logging/Loggable";
import { Sema } from "async-sema";
import { IMessageCache, IMessagePoller } from "../pollers";

export class IMessageListener extends Loggable {
    tag = "IMessageListener";

    stopped: boolean;

    filePaths: string[];

    watcher: MultiFileWatcher;

    processLock: Sema;

    pollers: IMessagePoller[];

    cache: IMessageCache;

    constructor({ filePaths, cache }: { filePaths: string[], cache: IMessageCache }) {
        super();

        this.filePaths = filePaths;
        this.pollers = [];
        this.cache = cache;
        this.stopped = false;
        this.processLock = new Sema(1);
    }

    stop() {
        this.stopped = true;
        this.removeAllListeners();
    }

    addPoller(poller: IMessagePoller) {
        this.pollers.push(poller);
    }

    start() {
        let lastCheck = 0;
        this.watcher = new MultiFileWatcher(this.filePaths);
        this.watcher.on("change", async event => {
            await this.processLock.acquire();

            // If we don't have a prevStat, it's a new file, and we still need to get entries.
            // If the prevStat is newer than the last check, we need to check.
            if (!event.prevStat || event.prevStat.mtimeMs > lastCheck) {
                // If we don't have a prevStat, we should use the currentStat's mtimeMs - 1 minute
                const after = event.prevStat?.mtimeMs ?? (event.currentStat.mtimeMs - 60000);

                // Invoke the different pollers
                for (const poller of this.pollers) {
                    const results = await poller.poll(new Date(after), null);
                    for (const result of results) {
                        this.emit(result.eventType, result.data);
                    }
                }

                // Trim the cache and save the last check
                this.cache.trimCaches();
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
}
