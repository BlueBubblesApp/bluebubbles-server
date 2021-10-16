import { Server } from "@server/index";
import { ValidTapback } from "@server/types";

import * as net from "net";
import { ValidRemoveTapback } from "../../types";

export class BlueBubblesHelperService {
    server: net.Server;

    helper: net.Socket;

    restartCounter: number;

    constructor() {
        this.restartCounter = 0;
    }

    configureServer() {
        this.server = net.createServer((socket: net.Socket) => {
            this.helper = socket;
            this.helper.setDefaultEncoding("utf8");

            this.setupListeners();
            Server().log("Private API Helper connected!");

            this.helper.on("close", () => {
                Server().log("Private API Helper disconnected!", "error");
                this.helper = null;
            });

            this.helper.on("error", () => {
                Server().log("An error occured in the BlueBubblesHelper connection! Closing...", "error");
                if (this.helper) this.helper.destroy();
            });
        });

        this.server.on("error", err => {
            Server().log("An error occured in the TCP Socket! Restarting", "error");
            Server().log(err.toString(), "error");

            if (this.restartCounter <= 5) {
                this.restartCounter += 1;
                this.start();
            } else {
                Server().log("Max restart count reached for Private API listener...");
            }
        });
    }

    start() {
        // Stop anything going on
        this.stop();

        // Configure & start the listener
        Server().log("Starting Private API Helper...", "debug");
        this.configureServer();

        // Listen and reset the restart counter
        this.server.listen(45677, "localhost", 511, () => {
            this.restartCounter = 0;
        });
    }

    stop() {
        try {
            if (this.helper && !this.helper.destroyed) {
                this.helper.destroy();
                this.helper = null;
            }
        } catch (ex: any) {
            Server().log(`Failed to stop Private API Helper! Error: ${ex.toString()}`);
        }

        try {
            if (this.server && this.server.listening) {
                Server().log("Stopping Private API Helper...", "debug");

                this.server.removeAllListeners();
                this.server.close();
                this.server = null;
            }
        } catch (ex: any) {
            Server().log(`Failed to stop Private API Helper! Error: ${ex.toString()}`);
        }
    }

    async startTyping(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to start typing, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to start typing, no chatGuid specified!", "error");
            return;
        }

        await this.writeData("start-typing", { chatGuid });
    }

    async stopTyping(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to stop typing, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to stop typing, no chatGuid specified!", "error");
            return;
        }

        await this.writeData("stop-typing", { chatGuid });
    }

    async markChatRead(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to mark chat as read, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to mark chat as read, no chatGuid specified!", "error");
            return;
        }

        await this.writeData("mark-chat-read", { chatGuid });
    }

    async sendReaction(chatGuid: string, selectedMessageGuid: string, reactionType: ValidTapback | ValidRemoveTapback) {
        if (!chatGuid || !selectedMessageGuid || !reactionType) {
            throw new Error("Failed to send reaction. Invalid params!");
        }

        await this.writeData("send-reaction", { chatGuid, selectedMessageGuid, reactionType });
    }

    async createChat(addresses: string[], message: string | null) {
        if (!addresses || addresses.length === 0) {
            throw new Error("Failed to send reaction. Invalid params!");
        }

        await this.writeData("create-chat", { addresses, message });
    }

    async sendMessage(
        chatGuid: string,
        message: string,
        subject: string = null,
        effectId: string = null,
        selectedMessageGuid: string = null
    ) {
        if (!chatGuid || !message) {
            throw new Error("Failed to send message. Invalid params!");
        }

        await this.writeData("send-message", { chatGuid, subject, message, effectId, selectedMessageGuid });
    }

    async addParticipant(chatGuid: string, address: string) {
        return this.toggleParticipant(chatGuid, address, "add");
    }

    async removeParticipant(chatGuid: string, address: string) {
        return this.toggleParticipant(chatGuid, address, "remove");
    }

    async toggleParticipant(chatGuid: string, address: string, action: "add" | "remove") {
        const msg = `Failed to ${action} participant to chat`;
        if (!this.helper || !this.server) {
            Server().log(`${msg}. BlueBubblesHelper is not running!`, "error");
            return;
        }

        if (!chatGuid || !address || !action) {
            Server().log(`${msg}. Invalid params!`, "error");
            return;
        }

        await this.writeData(`${action}-participant`, { chatGuid, address });
    }

    async setDisplayName(chatGuid: string, newName: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to send reaction, BlueBubblesHelper is not running!", "error");
            return;
        }

        if (!chatGuid || !newName) {
            Server().log("Failed to send reaction. Invalid params!", "error");
            return;
        }

        await this.writeData("set-display-name", { chatGuid, newName });
    }

    async getTypingStatus(chatGuid: string) {
        if (!this.helper || !this.server) {
            Server().log("Failed to retreive typing status, BlueBubblesHelper is not running!", "error");
            return;
        }
        if (!chatGuid) {
            Server().log("Failed to retreive typing status, no chatGuid specified!", "error");
            return;
        }

        await this.writeData("check-typing-status", { chatGuid });
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

    private async writeData(action: string, data: NodeJS.Dict<any>): Promise<void> {
        const msg = "Failed to send request to Private API!";

        try {
            await new Promise((resolve, reject) => {
                const d = { action, data };
                const res = this.helper.write(`${JSON.stringify(d)}\n`, (err: Error) => {
                    reject(err);
                });

                if (!res) {
                    reject(new Error("Unable to write to TCP Socket."));
                } else {
                    resolve(res);
                }
            });
        } catch (ex: any) {
            Server().log(`${msg} ${ex?.message ?? ex}`);
        }
    }
}
