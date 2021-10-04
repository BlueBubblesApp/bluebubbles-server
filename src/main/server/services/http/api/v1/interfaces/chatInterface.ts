import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import { Server } from "@server/index";
import { ChatResponse, HandleResponse } from "@server/types";

export class ChatRepository {
    static async get({
        guid = null,
        withSMS = false,
        withParticipants = true,
        withArchived = false,
        withLastMessage = false,
        offset = 0,
        limit = null,
        sort = "lastmessage"
    }: any): Promise<ChatResponse[]> {
        const chats = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
            withSMS,
            withParticipants,
            withLastMessage,
            offset,
            limit
        });

        // If the query is with the last message, it makes the participants list 1 for each chat
        // We need to fetch all the chats with their participants, then cache the participants
        // so we can merge the participant list with the chats
        const chatCache: { [key: string]: Handle[] } = {};
        const tmpChats = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
            withParticipants: true,
            withArchived,
            withSMS
        });

        for (const chat of tmpChats) {
            chatCache[chat.guid] = chat.participants;
        }

        const results = [];
        for (const chat of chats ?? []) {
            if (chat.guid.startsWith("urn:")) continue;
            const chatRes = await getChatResponse(chat);

            // Insert the cached participants from the original request
            if (Object.keys(chatCache).includes(chat.guid)) {
                chatRes.participants = await Promise.all(
                    chatCache[chat.guid].map(
                        async (e): Promise<HandleResponse> => {
                            const test = await getHandleResponse(e);
                            return test;
                        }
                    )
                );
            }

            if (withLastMessage) {
                // Set the last message, if applicable
                if (chatRes.messages && chatRes.messages.length > 0) {
                    [chatRes.lastMessage] = chatRes.messages;

                    // Remove the last message from the result
                    delete chatRes.messages;
                }
            }

            results.push(chatRes);
        }

        // If we have a sort parameter, handle the cases
        if (sort) {
            if (sort === "lastmessage" && withLastMessage) {
                results.sort((a: ChatResponse, b: ChatResponse) => {
                    const d1 = a.lastMessage?.dateCreated ?? 0;
                    const d2 = b.lastMessage?.dateCreated ?? 0;
                    if (d1 > d2) return -1;
                    if (d1 < d2) return 1;
                    return 0;
                });
            }
        }

        return results;
    }
}
