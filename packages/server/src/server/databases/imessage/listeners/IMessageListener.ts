import { EventCache } from "@server/eventCache";
import { MultiFileWatcher } from "@server/lib/MultiFileWatcher";
import { Loggable } from "@server/lib/logging/Loggable";
import { Sema } from "async-sema";
import { IMessageCache, IMessagePollResult, IMessagePoller } from "../pollers";
import { MessageRepository } from "..";
import { waitMs } from "@server/helpers/utils";

export class IMessageListener extends Loggable {
    tag = "IMessageListener";

    stopped: boolean;

    filePaths: string[];

    watcher: MultiFileWatcher;

    repo: MessageRepository;

    processLock: Sema;

    pollers: IMessagePoller[];

    cache: IMessageCache;

    constructor({ filePaths, repo, cache }: { filePaths: string[], repo: MessageRepository, cache: IMessageCache }) {
        super();

        this.filePaths = filePaths;
        this.repo = repo;
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

            if (event.currentStat.mtimeMs > lastCheck) {
                // Use the currentStat's mtimeMs - 10 seconds to account for any time drift.
                // due to the time it takes to write to the disk.
                const after = event.currentStat.mtimeMs - 10000;

                // Invoke the different pollers
                for (const poller of this.pollers) {
                    this.log.debug(`Polling ${poller.tag} for new entries after ${new Date(after).toISOString()}`);
                    const results = await poller.poll(new Date(after));
                    for (const result of results) {
                        this.emit(result.eventType, result.data);
                    }
                    this.log.debug(`Finished polling ${poller.tag}`);
                }

                // Trim the cache and save the last check
                this.cache.trimCaches();
                lastCheck = event.currentStat.mtimeMs;
            }

            if (this.processLock.nrWaiting() > 0) {
                await waitMs(10);
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
