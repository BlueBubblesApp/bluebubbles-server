import { getHandleResponse } from "@server/databases/imessage/entity/Handle";
import { Server } from "@server/index";
import { ChatResponse, HandleResponse } from "@server/types";
import { ChatInterface } from "./chatInterface";

export class HandleInterface {
    static async get({
        address = null,
        withChats = false,
        withChatParticipants = false,
        limit = null,
        offset = 0
    }: any): Promise<HandleResponse[]> {
        const handles = await Server().iMessageRepo.getHandles({
            address,
            limit,
            offset
        });

        // As long as there are results, we should fetch chats and match them
        const handleChatMap: { [key: string]: ChatResponse[] } = {};
        if (handles && withChats) {
            const chats = await ChatInterface.get({
                withParticipants: true,
                withLastMessage: false
            });

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
            handles.map(
                async (e): Promise<HandleResponse> => {
                    const test = await getHandleResponse(e);

                    // Add in the cached chats
                    if (withChats && Object.keys(handleChatMap).includes(test.address)) {
                        test.chats = handleChatMap[test.address];
                    }

                    return test;
                }
            )
        );

        return results;
    }
}
