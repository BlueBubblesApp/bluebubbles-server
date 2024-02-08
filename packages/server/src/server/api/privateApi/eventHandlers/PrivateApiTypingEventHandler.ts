import { Server } from "@server";
import * as net from "net";
import { TYPING_INDICATOR } from "@server/events";
import { PrivateApiEventHandler, EventData } from ".";

export class PrivateApiTypingEventHandler implements PrivateApiEventHandler {
    types: string[] = ["started-typing", "typing", "stopped-typing"];

    cache: Record<string, Record<string, any>> = {};

    async handle(data: EventData, _: net.Socket) {
        const display = data.event === "started-typing";
        const guid = data.guid;
        let shouldEmit = false;

        // Ignore typing events from group chats (they aren't "proper")
        if (guid.includes(";+;")) return;

        // If the guid hasn't been seen before, we should emit the event
        const now = new Date().getTime();
        if (!Object.keys(this.cache).includes(guid)) {
            shouldEmit = true;
        } else {
            // If the last value was different than the current value, we should emit the event
            if (this.cache[guid].lastValue !== display) {
                shouldEmit = true;
            } else {
                // If the value is the same, we should emit the event if it's been more than 5 seconds
                const lastSeen = this.cache[guid].lastSeen;
                if (now - lastSeen > 5000) {
                    shouldEmit = true;
                }
            }
        }

        if (shouldEmit) {
            // Update the cache values
            this.cache[guid] = {
                lastSeen: now,
                lastValue: display
            };

            Server().emitMessage(TYPING_INDICATOR, { display, guid }, "normal", false);
        }
    }
}
