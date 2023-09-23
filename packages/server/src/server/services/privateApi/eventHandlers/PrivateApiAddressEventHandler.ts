import { Server } from "@server";
import { IMESSAGE_ALIAS_REMOVED } from "@server/events";
import { EventData, PrivateApiEventHandler } from ".";


export class PrivateApiAddressEventHandler implements PrivateApiEventHandler {

    types: string[] = ["alias-removed"];

    cache: Record<string, Record<string, any>> = {};

    async handle(data: EventData) {
        if (data.event === 'alias-removed') {
            await this.handleDeregistration(data);
        }
    }

    async handleDeregistration(data: any) {
        const address = data.__kIMAccountAliasesRemovedKey ?? data.data?.__kIMAccountAliasesRemovedKey ?? null;
        if (!address) {
            return Server().log('iMessage address deregistration event received, but no address was found!', 'warn');
        }

        Server().emitMessage(IMESSAGE_ALIAS_REMOVED, { address }, "high", true);
    }
}