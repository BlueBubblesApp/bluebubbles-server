import { EventEmitter } from "events";

export class ScheduledService extends EventEmitter {
    eventName = "timeout";

    action: () => void;

    handle: NodeJS.Timer;

    interval: number;

    stopped = false;

    constructor(action: () => void, ms: number, autoStart = true) {
        super();
        this.action = action;
        this.handle = undefined;
        this.interval = ms;
        this.addListener(this.eventName, this.action);

        if (autoStart) {
            this.start();
        }
    }

    addCustomListener(listener: (...args: any[]) => void) {
        this.addListener(this.eventName, listener);
    }

    start() {
        this.stopped = false;
        if (!this.handle) {
            this.handle = setInterval(() => this.emit(this.eventName), this.interval);
        }
    }

    stop() {
        if (this.handle) {
            clearInterval(this.handle);
            this.handle = undefined;
            this.stopped = true;
        }
    }
}
