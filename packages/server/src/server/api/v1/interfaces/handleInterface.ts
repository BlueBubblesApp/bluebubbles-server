import { Server } from "@server";
import { ChatResponse, HandleResponse } from "@server/types";
import { HandleSerializer } from "../serializers/HandleSerializer";
import { ChatInterface } from "./chatInterface";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { checkPrivateApiStatus, getiMessageAddressFormat, isEmpty } from "@server/helpers/utils";
import { isMinMonterey } from "@server/env";

export class HandleInterface {
    static async get({
        address = null,
        withChats = false,
        withChatParticipants = false,
        limit = null,
        offset = 0
    }: any): Promise<[HandleResponse[], number]> {
        const [handles, total] = await Server().iMessageRepo.getHandles({
            address,
            limit,
            offset
        });

        // As long as there are results, we should fetch chats and match them
        const handleChatMap: { [key: string]: ChatResponse[] } = {};
        if (handles && withChats) {
            const [chats, _] = await ChatInterface.get();

            // Store chats (by address) in a cache for easy accessing
            for (const i of chats) {
                // Copy the participant list
                const participantsCopy = [...(i.participants ?? [])];

                // Remove the OG participant list if disabled
                if (!withChatParticipants && Object.keys(i).includes("participants")) {
                    delete i.participants;
                }

                // Store by address
                for (const h of participantsCopy) {
                    if (!Object.keys(handleChatMap).includes(h.address)) {
                        handleChatMap[h.address] = [i];
                    } else {
                        handleChatMap[h.address].push(i);
                    }
                }
            }
        }

        const results = await Promise.all(
            handles.map(async (e): Promise<HandleResponse> => {
                const test = await HandleSerializer.serialize({ handle: e });

                // Add in the cached chats
                if (withChats && Object.keys(handleChatMap).includes(test.address)) {
                    test.chats = handleChatMap[test.address];
                }

                return test;
            })
        );

        return [results, total];
    }

    static async getFocusStatus(handle: Handle): Promise<string> {
        checkPrivateApiStatus();
        if (!isMinMonterey) throw new Error("Focus status is only available on Monterey and newer!");

        const focusStatus = await Server().privateApi.handle.getFocusStatus(handle.id);
        if (isEmpty(focusStatus?.data)) return "unknown";

        if (focusStatus?.data?.silenced == 1) return "silenced";
        return "none";
    }

    static async getMessagesAvailability(address: string): Promise<boolean> {
        checkPrivateApiStatus();

        const addr = getiMessageAddressFormat(address);
        const availability = await Server().privateApi.handle.getMessagesAvailability(addr);
        if (isEmpty(availability?.data)) {
            throw new Error("Failed to determine iMessage availability!");
        }

        return !!availability?.data.available;
    }

    static async getFacetimeAvailability(address: string): Promise<boolean> {
        checkPrivateApiStatus();

        const addr = getiMessageAddressFormat(address);
        const availability = await Server().privateApi.handle.getFacetimeAvailability(addr);
        if (isEmpty(availability?.data)) {
            throw new Error("Failed to determine Facetime availability!");
        }

        return !!availability?.data.available;
    }
}
