import { Server } from "@server";
import * as net from "net";
import { FT_CALL_STATUS_CHANGED, INCOMING_FACETIME } from "@server/events";
import { EventData, PrivateApiEventHandler } from ".";
import { HandleResponse } from "@server/types";
import { slugifyAddress } from "@server/helpers/utils";
import { HandleSerializer } from "@server/api/serializers/HandleSerializer";
import { FaceTimeSessionManager } from "@server/api/lib/facetime/FacetimeSessionManager";
import { FaceTimeSession, FaceTimeSessionStatus, callStatusMap } from "@server/api/lib/facetime/FaceTimeSession";
import { Loggable } from "@server/lib/logging/Loggable";

type FaceTimeStatusData = {
    uuid: string;
    status_id: number;
    status: string;
    ended_error: string;
    ended_reason: string;
    address: string;
    handle?: HandleResponse;
    image_url: string;
    is_outgoing: boolean;
    is_audio: boolean;
    is_video: boolean;
    url?: string | null;
};

export class PrivateApiFaceTimeStatusHandler extends Loggable implements PrivateApiEventHandler {
    tag = "PrivateApiFaceTimeStatusHandler";

    types: string[] = ["ft-call-status-changed"];

    async handle(data: EventData, _: net.Socket) {
        const ft_calling = Server().repo.getConfig("facetime_calling") as boolean;
        if (ft_calling) {
            await this.handleCalling(data);
        } else {
            await this.handleStandard(data);
        }
    }

    // The commeneted out handler at the bottom should be used in 1.9.0
    async handleStandard(data: EventData) {
        // Ignore calls that are not incoming
        if (data.data.call_status !== FaceTimeSessionStatus.INCOMING) return;

        this.log.info(`Incoming FaceTime call from ${data.data?.handle?.value}`);

        // stringify to maintain backwards compat
        const output = JSON.stringify({
            caller: data.data?.handle?.value,
            timestamp: new Date().getTime()
        });

        Server().emitMessage(INCOMING_FACETIME, output, "high", true, true);
    }

    async handleCalling(data: EventData) {
        const session = FaceTimeSession.fromEvent(data.data);
        const isNew = FaceTimeSessionManager().addSession(session);

        // Don't do anything for outgoing calls
        if ([3].includes(data.data.call_status)) return;

        // When a call is answered, we don't need to emit an event
        if (data.data.call_status === FaceTimeSessionStatus.ANSWERED) {
            this.log.info(`FaceTime call answered (Call UUID: ${data.data.call_uuid})`);
            return;
        }

        // When a call is incoming, update the session
        // Don't emit an event if it was an existing session
        if (data.data.call_status === FaceTimeSessionStatus.INCOMING) {
            this.log.info(`Incoming FaceTime call from ${data.data.handle.value} (Call UUID: ${data.data.call_uuid})`);
            if (!isNew) return;
        }

        // If the call was disonnected, update the session, but still emit an event
        if (data.data.call_status === FaceTimeSessionStatus.DISCONNECTED && data.data.handle) {
            this.log.info(`FaceTime call disconnected with ${data.data.handle.value}`);
        }

        const addr = slugifyAddress(data.data.handle.value);
        const [handle, _] = await Server().iMessageRepo.getHandles({ address: addr, limit: 1 });

        // Build a payload to be sent out to clients.
        // We just alias some of the data to make it easier to work with.
        const output: FaceTimeStatusData = {
            uuid: data.data.call_uuid,
            status: callStatusMap[data.data.call_status] ?? "unknown",
            status_id: data.data.call_status,
            ended_error: data.data.ended_error,
            ended_reason: data.data.ended_reason,
            address: data.data.handle.value,
            handle: handle[0] ? await HandleSerializer.serialize({ handle: handle[0] }) : null,
            image_url: data.data.image_url ?? null,
            is_outgoing: data.data.is_outgoing ?? false,
            is_audio: data.data.is_sending_audio ?? false,
            is_video: data.data.is_sending_video ?? true
        };

        Server().emitMessage(FT_CALL_STATUS_CHANGED, output, "high", true);
    }
}
