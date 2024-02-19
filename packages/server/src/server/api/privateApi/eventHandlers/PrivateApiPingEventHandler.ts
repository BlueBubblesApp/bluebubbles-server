import { Server } from "@server";
import { PrivateApiEventHandler, EventData } from ".";
import { Socket } from "@server/api/types";
import { isNotEmpty } from "@server/helpers/utils";
import { Loggable } from "@server/lib/logging/Loggable";

export class PrivateApiPingEventHandler extends Loggable implements PrivateApiEventHandler {
    tag = "PrivateApiPingEventHandler";

    types: string[] = ["ping"];

    async handle(event: EventData, socket: Socket) {
        const proc = event?.process;
        this.log.info(`Received Ping from Private API Helper via ${proc ?? "Anonymous"}!`);
        if (isNotEmpty(proc)) {
            Server().privateApi.registerClient(proc, socket);
        }
    }
}
