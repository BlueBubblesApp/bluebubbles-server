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
    sockPath: string;

    helperPath: string;

    server: net.Server;

    helper: net.Socket = null;

    child: ChildProcess;

    queue: Queue = new Queue();

    private startServer() {
        fs.removeSync(this.sockPath);
        this.server = net.createServer(client => {
            Server().log("Swift Helper connected");
            client.on("end", () => {
                this.helper = null;
                Server().log("Swift Helper disconnected");
            });
            client.on("data", data => {
                const msg = Event.fromBytes(data);
                this.queue.call(msg.uuid, msg.data);
            });
            this.helper = client;
        });
        this.server.listen(this.sockPath);
    }

    private runSwiftHelper() {
        Server().log("Starting Swift Helper");
        this.child = spawn(this.helperPath, [this.sockPath]);
        this.child.stdout.setEncoding("utf8");
        // we should listen to stdout data
        // so we can forward to the bb logger
        this.child.stdout.on("data", data => {
            let si = data.indexOf(":");
            let level = data.substring(0, si);
            if (["log", "error", "warn", "debug"].indexOf(level) >= 0) {
                let content = data.substring(si+1);
                Server().log(`Swift Helper: ${content}`, level);
            } else {
                // log as error, should be using Logger in swiftHelper, not print
                Server().log(`Swift Helper: ${data}`, "error");
            }
        });
        this.child.stderr.setEncoding("utf8");
        this.child.stderr.on("data", data => {
            Server().log(`Swift Helper error: ${data}`);
        });
        // if the child process exits, we should restart it
        this.child.on("close", code => {
            Server().log("Swift Helper process exited: " + code);
            this.runSwiftHelper();
        });
    }

    /**
     * Initializes the Swift Helper service.
     */
    start() {
        this.helperPath = `${FileSystem.resources}/swiftHelper`;
        this.sockPath = `${app.getPath("userData")}/swift-helper.sock`;
        // Configure & start the socket server
        Server().log("Starting Swift Helper...", "debug");
        this.startServer();
        // we should set a 100 ms timeout to give time for the
        // socket server to start before connecting with the helper
        setTimeout(this.runSwiftHelper.bind(this), 100);
    }

    /**
     * Sends a Event to the Swift Helper process and listens for the response.
     * @param {Event} msg The Event to send.
     * @returns {Promise<Buffer | null>} A promise that resolves to the response message.
     */
    private async sendSocketEvent(msg: Event): Promise<Buffer | null> {
        return new Promise(resolve => {
            this.helper.write(msg.toBytes());
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
        if (blob != null && this.helper != null) {
            const msg = new Event("deserializeAttributedBody", Buffer.from(blob));
            const buf = await this.sendSocketEvent(msg);
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