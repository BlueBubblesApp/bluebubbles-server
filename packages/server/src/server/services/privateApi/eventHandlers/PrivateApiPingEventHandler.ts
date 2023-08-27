import { Server } from "@server";
import { PrivateApiEventHandler } from ".";


export class PrivateApiPingEventHandler implements PrivateApiEventHandler {

    types: string[] = ["ping"];

    async handle(_: any) {
        Server().log("Received Ping from Private API Helper!");
    }
}