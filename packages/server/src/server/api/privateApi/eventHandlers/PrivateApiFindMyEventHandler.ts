import { Server } from "@server";
import * as net from "net";
import { PrivateApiEventHandler, EventData } from ".";
import { FindMyLocationItem } from "@server/api/lib/findmy/types";
import { NEW_FINDMY_LOCATION } from "@server/events";
import { isEmpty, titleCase, waitMs } from "@server/helpers/utils";
import { Loggable } from "@server/lib/logging/Loggable";
import { obfuscatedHandle } from "@server/utils/StringUtils";

export class PrivateApiFindMyEventHandler extends Loggable implements PrivateApiEventHandler {
    tag = "PrivateApiFindMyEventHandler";

    types: string[] = ["new-findmy-location"];

    async handle(event: EventData, _: net.Socket) {
        try {
            if (event.event === "new-findmy-location") {
                await this.handleNewLocation(event.data);
            }
        } catch (ex: any) {
            this.log.debug(`Failed to handle event type ${event.event}. Error: ${ex}`);
        }
    }

    async handleNewLocation(data: FindMyLocationItem[]) {
        if (isEmpty(data)) return;

        // Store the data in the cache
        const added = Server().findMyCache?.addAll(data);

        // If there were items updated in the cache, emit them
        let count = 0;
        for (const item of added) {
            const handle = obfuscatedHandle(item?.handle);
            if (item?.coordinates[0] === 0 && item?.coordinates[1] === 0) {
                this.log.debug(`Received FindMy ${titleCase(item.status)} (0, 0) Location Update for Handle: ${handle}`);
            } else {
                this.log.debug(`Received FindMy ${titleCase(item.status)} Location Update for Handle: ${handle}`);
            }

            await Server().emitMessage(NEW_FINDMY_LOCATION, item, "normal", false, true);
            count++;

            // Rate limit the emitted events
            if (count < added.length) {
                await waitMs(250);
            }
        }
    }
}
