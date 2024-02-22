import { Logger } from "./Logger";

export class LoggerRegistry {
    private static _instance: LoggerRegistry;

    private loggers: any;

    private constructor() {
        this.loggers = {};
    }

    static get instance() {
        if (!this._instance) this._instance = new LoggerRegistry();
        return this._instance;
    }

    getLogger(tag: string) {
        if (!this.loggers[tag]) {
            this.loggers[tag] = new Logger(tag);
        }

        return this.loggers[tag];
    }
}
