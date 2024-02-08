import { Server } from "@server";
import { PrivateApiEventHandler, EventData } from ".";
import { Socket } from "@server/api/types";
import { isNotEmpty } from "@server/helpers/utils";

export class PrivateApiPingEventHandler implements PrivateApiEventHandler {
    types: string[] = ["ping"];

    async handle(event: EventData, socket: Socket) {
        const proc = event?.process;
        Server().log(`Received Ping from Private API Helper via ${proc ?? "Anonymous"}!`);
        if (isNotEmpty(proc)) {
            Server().privateApi.registerClient(proc, socket);
        }
    }
}
