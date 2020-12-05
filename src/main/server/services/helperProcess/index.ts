import { Server } from "@server/index";

import * as net from "net";

export class BlueBubblesHelperService {
    server: net.Server;

    helper: net.Socket;

    constructor() {
        this.server = net.createServer((socket: net.Socket) => {
            this.helper = socket;
            this.helper.setDefaultEncoding("utf8");
            this.setupListeners();
            Server().log("Helper connected!");

            this.helper.on("close", () => {
                Server().log("Helper disconnected!", "error");
                this.helper = null;
            });
            this.helper.on("error", () => {
                Server().log("An error occured in the BlueBubblesHelper connection! Closing...", "error");
                if (this.helper) this.helper.destroy();
            });
        });
        this.server.on("error", () => {
            Server().log("An error occured in the TCP Socket! Retarting", "error");
            this.server.close();
            this.start();
        });
    }

    start() {
        this.server.close();
        this.server.listen(45677, "localhost");
    }

    startTyping(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to start typing, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to start typing, no chatGuid specified!", "error");
            return;
        }

        const data = {
            event: "start-typing",
            data: chatGuid
        };
        if (!this.helper.write(`${JSON.stringify(data)}\n`)) {
            Server().log("Failed to start typing, an error occured writing to the socket", "error");
        }
    }

    stopTyping(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to stop typing, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to stop typing, no chatGuid specified!", "error");
            return;
        }

        const data = {
            event: "stop-typing",
            data: chatGuid
        };
        if (!this.helper.write(`${JSON.stringify(data)}\n`)) {
            Server().log("Failed to stop typing, an error occured writing to the socket", "error");
        }
    }

    markChatRead(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to mark chat as read, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to mark chat as read, no chatGuid specified!", "error");
            return;
        }

        const data = {
            event: "mark-chat-read",
            data: chatGuid
        };
        if (!this.helper.write(`${JSON.stringify(data)}\n`)) {
            Server().log("Failed to mark chat as read, an error occured writing to the socket", "error");
        }
    }

    sendReaction(chatGuid: string, actionMessageGuid: string, reactionType: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to send reaction, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid || !actionMessageGuid || !reactionType) {
            Server().log("Failed to send reaction. Invalid params!", "error");
            return;
        }
        const data = {
            event: "send-reaction",
            data: `${chatGuid},${actionMessageGuid},${reactionType}`
        };
        if (!this.helper.write(`${JSON.stringify(data)}\n`)) {
            Server().log("Failed to send reaction, an error occured writing to the socket", "error");
        }
    }

    getTypingStatus(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to retreive typing status, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to retreive typing status, no chatGuid specified!", "error");
            return;
        }

        const data = {
            event: "check-typing-status",
            data: chatGuid
        };
        if (!this.helper.write(`${JSON.stringify(data)}\n`)) {
            Server().log("Failed to retreive typing status, an error occured writing to the socket", "error");
        }
    }

    setupListeners() {
        this.helper.on("data", (eventRaw: string) => {
            if (eventRaw == null) {
                Server().log(`Failed to decode null helper data!`);
                return;
            }

            const eventData: string[] = String(eventRaw).split("\n");
            const event = eventData[eventData.length - 2];
            if (event == null) {
                Server().log(`Failed to decode null helper data!`);
                return;
            }

            let data;
            try {
                data = JSON.parse(event);
            } catch (e) {
                Server().log(`Failed to decode helper data! ${event}, ${e}`);
                return;
            }
            if (data == null) return;
            if (data.event === "started-typing") {
                Server().emitMessage("typing-indicator", { display: true, guid: data.guid });
                Server().log(`Started typing! ${data.guid}`);
            } else if (data.event === "stopped-typing") {
                Server().emitMessage("typing-indicator", { display: false, guid: data.guid });
                Server().log(`Stopped typing! ${data.guid}`);
            }
        });
    }
}
