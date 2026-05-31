import fs from "fs";
import { MultiFileWatcher } from "@server/lib/MultiFileWatcher";
import type { FileChangeEvent } from "@server/lib/MultiFileWatcher";
import { Loggable } from "@server/lib/logging/Loggable";
import { Sema } from "async-sema";
import { IMessageCache, IMessagePoller } from "../pollers";
import { MessageRepository } from "..";
import { waitMs } from "@server/helpers/utils";
import { DebounceSubsequentWithWait } from "@server/lib/decorators/DebounceDecorator";

export class IMessageListener extends Loggable {
    tag = "IMessageListener";

    stopped: boolean;

    filePaths: string[];

    watcher: MultiFileWatcher;

    repo: MessageRepository;

    processLock: Sema;

    pollers: IMessagePoller[];

    cache: IMessageCache;

    lastCheck = 0;

    startedAt = 0;

    lastPollStartedAt = 0;

    lastPollFinishedAt = 0;

    lastPollErrorAt = 0;

    lastChangeEventAt = 0;

    pollInFlight = false;

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
        this.watcher?.stop();
        this.watcher = null;
        this.removeAllListeners();
    }

    addPoller(poller: IMessagePoller) {
        this.pollers.push(poller);
    }

    getEarliestModifiedDate() {
        let earliest = new Date();
        for (const filePath of this.filePaths) {
            const stat = fs.statSync(filePath);
            if (stat.mtime < earliest) {
                earliest = stat.mtime;
            }
        }

        return earliest;
    }

    async start() {
        this.startedAt = Date.now();
        this.lastCheck = this.getEarliestModifiedDate().getTime() - 60000;
        this.stopped = false;

        // Perform an initial poll to kinda seed the cache.
        // We'll use the earliest modified date of the files to determine the initial poll date.
        // We'll also subtract 1 minute just to pre-load the cache with a little bit of data.
        await this.poll(new Date(this.lastCheck), false);

        this.watcher = new MultiFileWatcher(this.filePaths);
        this.watcher.on("change", async (event: FileChangeEvent) => {
            await this.handleChangeEvent(event);
        });

        this.watcher.on("error", (error) => {
            this.log.error(`Failed to watch database files: ${this.filePaths.join(", ")}`);
            this.log.debug(`Error: ${error}`);
        });

        this.watcher.start();
    }

    @DebounceSubsequentWithWait('IMessageListener.handleChangeEvent', 500)
    async handleChangeEvent(event: FileChangeEvent) {
        this.lastChangeEventAt = Date.now();
        await this.processLock.acquire();
        try {
            const now = Date.now();
            let prevTime = this.lastCheck;
    
            if (prevTime <= 0 || prevTime > now) {
                this.log.debug(`Previous time is invalid (${prevTime}), setting to now...`);
                prevTime = now;
            } else if (now - prevTime > 86400000) {
                this.log.debug(`Previous time is > 24 hours ago, setting to 24 hours ago...`);
                prevTime = now - 86400000;
            }
    
            let afterTime = prevTime - 30000;
            if (afterTime > now) {
                afterTime = now;
            }
            await this.poll(new Date(afterTime));
            this.lastCheck = now;
    
            this.cache.trimCaches();
            if (this.processLock.nrWaiting() > 0) {
                await waitMs(100);
            }
        } catch (error) {
            this.log.error(`Error handling change event: ${error}`);
        } finally {
            this.processLock.release();
        }
    }

    async poll(after: Date, emitResults = true) {
        this.pollInFlight = true;
        this.lastPollStartedAt = Date.now();

        try {
            for (const poller of this.pollers) {
                const results = await poller.poll(after);

                if (emitResults) {
                    for (const result of results) {
                        await this.emitAsync(result.eventType, result.data);
                        await waitMs(10);
                    }
                }
            }
            this.lastPollFinishedAt = Date.now();
        } catch (ex: any) {
            this.lastPollErrorAt = Date.now();
            throw ex;
        } finally {
            this.pollInFlight = false;
        }
    }

    async heartbeat(after: Date) {
        await this.processLock.acquire();
        try {
            await this.poll(after);
            this.lastCheck = Date.now();
            this.cache.trimCaches();
        } finally {
            this.processLock.release();
        }
    }

    private async emitAsync(eventType: string, data: any) {
        const listeners = this.listeners(eventType);
        for (const listener of listeners) {
            await listener(data);
        }
    }

    getHeartbeat() {
        return {
            stopped: this.stopped,
            startedAt: this.startedAt,
            lastCheck: this.lastCheck,
            lastChangeEventAt: this.lastChangeEventAt,
            lastPollStartedAt: this.lastPollStartedAt,
            lastPollFinishedAt: this.lastPollFinishedAt,
            lastPollErrorAt: this.lastPollErrorAt,
            pollInFlight: this.pollInFlight,
            waitingPolls: this.processLock.nrWaiting(),
            watcherActive: this.watcher != null
        };
    }
}
