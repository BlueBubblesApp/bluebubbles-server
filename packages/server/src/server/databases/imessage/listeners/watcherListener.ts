import { EventCache } from "@server/eventCache";
import { waitMs } from "@server/helpers/utils";
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

        // let lastCheck: number = new Date().getTime();
        this.watcher = new MultiFileWatcher(this.filePaths);

        let debounceTimeout: NodeJS.Timeout | null = null;

        const handleEvent = async (event: any) => {
            if (debounceTimeout) clearTimeout(debounceTimeout);

            debounceTimeout = setTimeout(async () => {
                // await this.getEntries(new Date(), null);
                // this.checkCache();

                console.log('Handling heavy code');
                await waitMs(5000);
                console.log('Heavy code handled');
                debounceTimeout = null;
            }, 1000);
        };

        this.watcher.on("change", async event => {
            if (!debounceTimeout) {
                handleEvent(event);
            }
        });

        this.watcher.start();
    }

    abstract getEntries(after: Date, before: Date | null): Promise<void>;
}
