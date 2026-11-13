import { Server } from "@server";
import EventEmitter from "events";

export class Logger extends EventEmitter {
    tag: string;

    constructor(tag: string) {
        super();
        this.tag = tag;
    }

    info(message: string) {
        Server().log(`[${this.tag}] ${message}`);
        this.emit("log", message);
    }

    debug(message: string) {
        Server().log(`[${this.tag}] ${message}`, "debug");
        this.emit("log", message);
    }

    error(message: string) {
        Server().log(`[${this.tag}] ${message}`, "error");
        this.emit("log", message);
    }

    warn(message: string) {
        Server().log(`[${this.tag}] ${message}`, "warn");
        this.emit("log", message);
    }
}
