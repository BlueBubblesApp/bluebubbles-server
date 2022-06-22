import { Server } from "@server/index";
import * as net from "net";
import * as fs from "fs-extra";
import { ChildProcess, spawn } from "child_process";
import { FileSystem } from "@server/fileSystem";
import { Event } from "./event";
import { Queue } from "./queue";
import { isNotEmpty } from "@server/helpers/utils";

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
                data.indexOf("\u0004")
                // split data by the EOT character
                const events = [];
                let lastI = 0;
                for (let i = 0; i < data.length; i++) {
                    if (data[i] === 0x04) {
                        events.push(data.slice(lastI, i));
                        lastI = i + 1;
                    }
                }

                events.forEach(event => {
                    const msg = Event.fromBytes(event);
                    this.queue.call(msg.uuid, msg.data);
                });
            });

            this.helper = client;
        });

        this.server.listen(this.sockPath);
    }

    private runSwiftHelper() {
        this.child = spawn(this.helperPath, [this.sockPath]);
        this.child.stdout.setEncoding("utf8");

        // we should listen to stdout data
        // so we can forward to the bb logger
        this.child.stdout.on("data", (data: string) => {
            // multiple lines can be returned if written in quick succession
            // therefore we should pass the ascii EOT (\u0004)
            // at the end of each log and split by the EOT character
            const lines = data.split("\u0004");
            lines.pop();

            for (const line of lines) {
                const splitIndex = line.indexOf(":");
                const level = line.substring(0, splitIndex);
                if (["log", "error", "warn", "debug"].indexOf(level) >= 0) {
                    const content = line.substring(splitIndex + 1);
                    Server().log(`[Swift Helper] ${content}`, level as any);
                } else {
                    Server().log(`[Swift Helper] ${line}`, "debug");
                }
            }
        });

        this.child.stderr.setEncoding("utf8");
        this.child.stderr.on("data", data => {
            Server().log(`[Swift Helper] Error: ${data}`, "debug");
        });

        // if the child process exits, we should restart it
        this.child.on("close", code => {
            Server().log(`Swift Helper process exited: ${code}`, "debug");
            this.runSwiftHelper();
        });
    }

    /**
     * Initializes the Swift Helper service.
     */
    start() {
        Server().log("Starting Swift Helper...");

        this.helperPath = `${FileSystem.resources}/swiftHelper`;
        this.sockPath = `${FileSystem.baseDir}/swift-helper.sock`;

        // Configure & start the socket server
        this.startServer();

        // we should set a 100 ms timeout to give time for the
        // socket server to start before connecting with the helper
        setTimeout(this.runSwiftHelper.bind(this), 100);
    }

    stop() {
        Server().log('Stopping Swift Helper...');

        if (this.child?.stdout) this.child.stdout.removeAllListeners();
        if (this.child?.stderr) this.child.stderr.removeAllListeners();
        if (this.child) {
            this.child.removeAllListeners();
            this.child.kill();
        }

        if (this.helper) {
            this.helper.destroy();
            this.helper = null;
        }

        if (this.server) {
            this.server.close();
            this.server = null;
        }
    }

    restart() {
        this.stop();
        this.start();
    }

    /**
     * Sends a Event to the Swift Helper process and listens for the response.
     * @param {Event} msg The Event to send.
     * @param {number} timeout The timeout in milliseconds, defaults to 1000.
     * @returns {Promise<Buffer | null>} A promise that resolves to the response message.
     */
    private async sendSocketEvent(msg: Event, timeout=1000): Promise<Buffer | null> {
        return new Promise(resolve => {
            this.helper.write(msg.toBytes());
            this.queue.enqueue(msg.uuid, resolve, timeout);
        });
    }

    /**
     * Deserializes an attributedBody blob into a json object using the swift helper.
     * @param {Blob} blob The attributedBody blob to deserialize.
     * @returns {Promise<Record<string, any>>} The deserialized json object.
     */
    async deserializeAttributedBody(blob: Blob | null): Promise<Record<string, any>> {
        // if the blob is null or our helper isn't connected, we should return null
        if (isNotEmpty(blob) && this.helper && this.helper.writable) {
            try {
                const msg = new Event("deserializeAttributedBody", Buffer.from(blob));
                const buf = await this.sendSocketEvent(msg, 250);
                // in case the helper process returns something weird,
                // catch any exceptions that would come from deserializing it and return null
                if (buf != null) {
                    try {
                        return JSON.parse(buf.toString());
                    } catch (e) {
                        Server().log("SwiftHelper returned invalid json: " + buf.toString(), "debug");
                        Server().log(e);
                    }
                }
            } catch (ex: any) {
                Server().log(`Failed to deserialize Attributed Body! Error: ${ex?.message ?? String(ex)}`, 'debug');
            }
        }

        return null;
    }
}