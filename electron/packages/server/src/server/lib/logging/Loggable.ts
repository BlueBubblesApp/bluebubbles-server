import EventEmitter from "events";
import { Logger } from "./Logger";

const loggers: Record<string, Logger> = {};

export const getLogger = (tag: string) => {
    let logger = loggers[tag];
    if (!logger) {
        logger = new Logger(tag);
        loggers[tag] = logger;
    }

    return logger;
};

export class Loggable extends EventEmitter {
    tag: string;

    get log() {
        const name = this.tag ?? this.constructor.name;
        return getLogger(name);
    }

    constructor(tag?: string) {
        super();

        if (tag) {
            this.tag = tag;
        }
    }

    onLog(listener: (message: string) => void) {
        this.log.on("log", listener);
    }
}
