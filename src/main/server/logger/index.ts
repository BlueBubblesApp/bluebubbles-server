import { EventEmitter } from "events";

interface EventEmitterOptions {
    /**
     * Enables automatic capturing of promise rejection.
     */
    captureRejections?: boolean;
}

export enum LogType {
    INFO = "info",
    DEBUG = "debug",
    WARN = "warn",
    ERROR = "error"
}

export type NewLog = {
    type: LogType;
    message: string;
};

/**
 * Basically a proxy for Electron Log so if needed,
 * we can have some control over what is logged
 */
export abstract class LoggerMixin extends EventEmitter {
    name: string;

    constructor(name: string, eventEmitterOptions?: EventEmitterOptions) {
        super(eventEmitterOptions);

        this.name = name;
    }

    /**
     * Handler for sending logs. This allows us to also route
     * the logs to the main Electron window
     *
     * @param type The log type
     * @param message The message to print
     */
    abstract log(message: string, type: LogType): NewLog;

    info(message: string) {
        const newLog = this.log(this.formatMessage(message), LogType.INFO);
        this.emit("new-log", newLog);
    }

    error(message: string) {
        const newLog = this.log(this.formatMessage(message), LogType.ERROR);
        this.emit("new-log", newLog);
    }

    warn(message: string) {
        const newLog = this.log(this.formatMessage(message), LogType.WARN);
        this.emit("new-log", newLog);
    }

    debug(message: string) {
        const newLog = this.log(this.formatMessage(message), LogType.DEBUG);
        this.emit("new-log", newLog);
    }

    private formatMessage(message: string): string {
        return `[${this.name}]: ${message}`;
    }
}
