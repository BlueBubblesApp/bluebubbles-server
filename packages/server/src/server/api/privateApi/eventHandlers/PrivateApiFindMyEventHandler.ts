import { Server } from "@server";
import * as net from "net";
import { PrivateApiEventHandler, EventData } from ".";
import { FindMyFriendLocation } from "@server/api/lib/findmy/types";
import { normalizeFindMyFriendLocations } from "@server/api/lib/findmy/utils";
import { NEW_FINDMY_LOCATION } from "@server/events";
import { isEmpty, titleCase, waitMs } from "@server/helpers/utils";
import { Loggable } from "@server/lib/logging/Loggable";
import { obfuscatedHandle } from "@server/utils/StringUtils";

export class PrivateApiFindMyEventHandler extends Loggable implements PrivateApiEventHandler {
    tag = "PrivateApiFindMyEventHandler";

    types: string[] = ["new-findmy-location"];

    async handle(eventData: EventData, _socket: net.Socket) {
        try {
            if (eventData.event === "new-findmy-location") {
                await this.handleNewLocations(eventData.data);
            }
        } catch (error: any) {
            this.log.debug(`Failed to handle event type ${eventData.event}. Error: ${error}`);
        }
    }

    async handleNewLocations(locationUpdates: FindMyFriendLocation[]) {
        if (isEmpty(locationUpdates)) return;
        const normalizedLocations = normalizeFindMyFriendLocations(locationUpdates);
        const updatedLocations = Server().findMyFriendsCache.updateAll(normalizedLocations);

        let emittedLocationCount = 0;
        for (const location of updatedLocations) {
            const handle = obfuscatedHandle(location.handle);
            const coordinates = location.coordinates;
            if (coordinates == null) {
                this.log.debug(
                    `Received FindMy ${titleCase(location.status)} Update Without a Location for Handle: ${handle}`
                );
            } else if (coordinates[0] === 0 && coordinates[1] === 0) {
                this.log.debug(
                    `Received FindMy ${titleCase(location.status)} (0, 0) Location Update for Handle: ${handle}`
                );
            } else {
                this.log.debug(`Received FindMy ${titleCase(location.status)} Location Update for Handle: ${handle}`);
            }

            await Server().emitMessage(NEW_FINDMY_LOCATION, location, "normal", false, true);
            emittedLocationCount += 1;

            if (emittedLocationCount < updatedLocations.length) {
                await waitMs(250);
            }
        }
    }
}
