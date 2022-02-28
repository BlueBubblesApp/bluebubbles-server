import { Server } from "@server/index";
import * as net from "net";
import * as fs from "fs-extra";
import { ChildProcess, spawn } from "child_process";
import { app } from "electron";
import { FileSystem } from "@server/fileSystem";
import { Event } from "./event";
import { Queue } from "./queue";

/**
 * A class that handles the communication with the swift helper process.
 */
export class SwiftHelperService {
    helperPath: string;

    server: net.Server;

    child: ChildProcess;

    queue: Queue = new Queue();

    constructor() {
        this.helperPath = `${FileSystem.resources}/swiftHelper`;
    }

    private onEvent(data: Buffer) {
        //Server().log(`Swift Helper: ${data.toString().trim()}`, "debug");
        // try to parse event
        const msg = Event.fromBytes(data);
        if (msg.event == "log") {
            // if event is log, then we should log the message
            let data = msg.data.toString();
            let si = data.indexOf(":");
            let level = data.substring(0, si) as "log" | "error" | "warn" | "debug";
            let content = data.substring(si+1);
            Server().log(`Swift Helper: ${content}`, level);
        } else {
            // else we should complete the promise
            this.queue.call(msg.uuid, msg.data);
        }
    }

    /**
     * Initializes the Swift Helper service.
     */
    start() {
        Server().log("Starting Swift Helper");
        this.child = spawn(this.helperPath);
        // we should listen to stdout data to recieve events
        this.child.stdout.on("data", this.onEvent);
        // also listen for stderr and log
        this.child.stderr.setEncoding("ascii");
        this.child.stderr.on("data", data => {
            Server().log(`Swift Helper error: ${data}`);
        });
        // if the child process exits, we should restart it
        this.child.on("close", code => {
            Server().log("Swift Helper process exited");
            this.start();
        });
    }

    /**
     * Sends a SocketMessage to the Swift Helper process and listens for the response.
     * @param {Event} msg The SocketMessage to send.
     * @returns {Promise<Buffer | null>} A promise that resolves to the response message.
     */
    private async sendSocketMessage(msg: Event): Promise<Buffer | null> {
        return new Promise(resolve => {
            this.child.stdin.write(msg.toBytes());
            this.queue.enqueue(msg.uuid, resolve);
        });
    }

    /**
     * Deserializes an attributedBody blob into a json object using the swift helper.
     * @param {Blob} blob The attributedBody blob to deserialize.
     * @returns {Promise<Record<string, any>>} The deserialized json object.
     */
    async deserializeAttributedBody(blob: Blob | null): Promise<Record<string, any>> {
        // if the blob is null or our helper isn't connected, we should return null
        if (blob != null && this.child.connected) {
            const msg = new Event("deserializeAttributedBody", Buffer.from(blob));
            const buf = await this.sendSocketMessage(msg);
            // in case the helper process returns something weird,
            // catch any exceptions that would come from deserializing it and return null
            if (buf != null) {
                try {
                    return JSON.parse(buf.toString());
                } catch (e) {
                    Server().log(e);
                }
            }
        }
        return null;
    }
}
