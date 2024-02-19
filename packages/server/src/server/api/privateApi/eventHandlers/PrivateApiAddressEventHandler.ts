import { Server } from "@server";
import * as net from "net";
import { IMESSAGE_ALIASES_REMOVED } from "@server/events";
import { EventData, PrivateApiEventHandler } from ".";
import { isEmpty } from "@server/helpers/utils";
import { Loggable } from "@server/lib/logging/Loggable";

export class PrivateApiAddressEventHandler extends Loggable implements PrivateApiEventHandler {
    tag = "PrivateApiAddressEventHandler";

    types: string[] = ["aliases-removed"];

    cache: Record<string, Record<string, any>> = {};

    async handle(data: EventData, _: net.Socket) {
        if (data.event === "aliases-removed") {
            await this.handleDeregistration(data);
        }
    }

    async handleDeregistration(data: EventData) {
        const aliases = data.data?.__kIMAccountAliasesRemovedKey ?? [];
        if (isEmpty(aliases)) {
            return this.log.warn("iMessage address deregistration event received, but no address was found!");
        }

        Server().emitMessage(IMESSAGE_ALIASES_REMOVED, { aliases }, "high", true);
    }
}
