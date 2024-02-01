import { Server } from "@server";
import * as net from "net";
import { IMESSAGE_ALIASES_REMOVED } from "@server/events";
import { EventData, PrivateApiEventHandler } from ".";
import { isEmpty } from "@server/helpers/utils";

export class PrivateApiAddressEventHandler implements PrivateApiEventHandler {
    types: string[] = ["aliases-removed"];

    cache: Record<string, Record<string, any>> = {};

    async handle(data: EventData, _: net.Socket) {
        if (data.event === "aliases-removed") {
            await this.handleDeregistration(data);
        }
    }

    async handleDeregistration(data: EventData) {
        const addresses = data.data?.__kIMAccountAliasesRemovedKey ?? [];
        if (isEmpty(addresses)) {
            return Server().log("iMessage address deregistration event received, but no address was found!", "warn");
        }

        Server().emitMessage(IMESSAGE_ALIASES_REMOVED, { addresses }, "high", true);
    }
}
