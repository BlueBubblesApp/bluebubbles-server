import { Server } from "@server";
import { FT_CALL_STATUS_CHANGED } from "@server/events";
import { EventData, PrivateApiEventHandler } from ".";


export class PrivateApiFaceTimeStatusHandler implements PrivateApiEventHandler {

    types: string[] = ["ft-call-status-changed"];

    callStatusMap: Record<number, string> = {
        4: "incoming",
        6: "disconnected",
    };

    async handle(data: EventData) {
        console.log(data);
        Server().emitMessage(FT_CALL_STATUS_CHANGED, data, "high", true);
    }
}