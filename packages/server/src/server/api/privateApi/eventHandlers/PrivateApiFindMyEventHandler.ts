import { Server } from "@server";
import * as net from "net";
import { PrivateApiEventHandler, EventData } from ".";
import { FindMyLocationItem } from "@server/api/lib/findmy/types";
import { NEW_FINDMY_LOCATION } from "@server/events";
import { isEmpty, isNotEmpty, waitMs } from "@server/helpers/utils";

export class PrivateApiFindMyEventHandler implements PrivateApiEventHandler {
    types: string[] = ["new-findmy-location"];

    async handle(event: EventData, _: net.Socket) {
        try {
            if (event.event === "new-findmy-location") {
                await this.handleNewLocation(event.data);
            }
        } catch (ex: any) {
            Server().log(`Failed to handle event type ${event.event}. Error: ${ex}`, "debug");
        }
    }

    async handleNewLocation(data: FindMyLocationItem[]) {
        if (isEmpty(data)) return;

        // Store the data in the cache
        const added = Server().findMyCache?.addAll(data);

        // If there were items updated in the cache, emit them
        let count = 0;
        for (const item of added) {
            Server().log(`Received FindMy Location Update for Handle: ${item?.handle}`, "debug");
            await Server().emitMessage(NEW_FINDMY_LOCATION, item, "normal", false, true);
            count++;

            // Rate limit the emitted events
            if (count < added.length) {
                await waitMs(250);
            }
        }
    }
}
