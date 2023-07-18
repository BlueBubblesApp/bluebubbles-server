import { Server } from "@server";
import { PrivateApiEventHandler } from ".";


export class PrivateApiPingEventHandler implements PrivateApiEventHandler {

    types: string[] = ["ping"];

    async handle(_: any) {
        Server().log("Private API Helper connected!");
    }
}