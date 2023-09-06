import { Server } from "@server";
import { PrivateApiEventHandler, EventData } from ".";


export class PrivateApiPingEventHandler implements PrivateApiEventHandler {

    types: string[] = ["ping"];

    async handle(_: EventData) {
        Server().log("Received Ping from Private API Helper!");
    }
}