import fs from "fs";
import { Loggable } from "./logging/Loggable";

export type FileStat = fs.Stats | null | undefined;

export type FileChangeHandlerCallback = (event: FileChangeEvent) => Promise<void>;

export type FileChangeEvent = {
    type: 'changed' | 'created';
    nextStat: FileStat;
    prevStat: FileStat;
    filePath: string;
}

export class MultiFileWatcher extends Loggable {
    tag = "MultiFileWatcher";

    private readonly filePaths: string[];

    private watchers: fs.StatWatcher[];

    private isProcessing: boolean = false;

    private handler: FileChangeHandlerCallback;

    private queuedEvent?: FileChangeEvent;

    private shouldStop = false;
  
    constructor(filePaths: string[], handler: FileChangeHandlerCallback) {
        super();

        this.filePaths = filePaths;
        this.handler = handler;
        this.filePaths.forEach((filePath) => this.watchFile(filePath));
    }
  
    private watchFile(filePath: string) {
        const watcher = fs.watchFile(filePath, (nextStat: FileStat, prevStat: FileStat) => {
            const type = prevStat ? 'changed' : 'created';
            this.handleFileEvent({ type, nextStat, prevStat, filePath });
        });

        this.watchers.push({ filePath, watcher });
    }
  
    private async handleFileEvent(event: FileChangeEvent) {
        if (!this.queuedEvent) {
            // Only queue event if no queued event exists
            this.queuedEvent = event;
            if (!this.isProcessing) {
                await this.processNextEvent();
            }
        }
    }
  
    /**
     * Processes the queued up event.
     * 
     * If any new events come in during the execution of the
     * handler, the first new event will be handled after
     * the original event. Any events that fire after the first
     * event during the handlers execution will be dropped.
     */
    private async processNextEvent() {
        this.isProcessing = true;

        // This is a while loop so that if any new events come in while
        // processing is still occuring, we handle those events. However,
        // we only need to handle the "earliest" one in the case of multiple.
        while (this.queuedEvent) {
            if (this.shouldStop) break;

            const event = this.queuedEvent;
            this.queuedEvent = null;

            try {
                await this.handler(event);
            } catch (ex) {
                this.log.debug('An error occured while handling a file change event!');
                this.log.debug(`Error: ${ex}`);
            }
        }

        this.isProcessing = false;
    }

    stop() {
        this.shouldStop = true;
        for (const watcher of this.watchers) {
            watcher.close();
        }
    }
}