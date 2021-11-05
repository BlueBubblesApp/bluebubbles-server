import { Chat, getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import { checkPrivateApiStatus, slugifyAddress, waitMs } from "@server/helpers/utils";
import { Server } from "@server/index";
import { ChatResponse, HandleResponse } from "@server/types";

export class ChatInterface {
    static async get({
        guid = null,
        withParticipants = true,
        withArchived = false,
        withLastMessage = false,
        offset = 0,
        limit = null,
        sort = "lastmessage"
    }: any): Promise<ChatResponse[]> {
        const chats = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
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
            withArchived
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

    static async setDisplayName(chat: Chat, displayName: string): Promise<Chat> {
        let theChat = chat;
        const prevName = chat.displayName;
        let newName = chat.displayName;

        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (chat.participants.length === 1) {
            throw new Error("Chat is not a group chat!");
        }

        await Server().privateApiHelper.setDisplayName(theChat.guid, displayName);

        let tryCount = 0;
        while (newName === prevName) {
            tryCount += 1;

            // If we've tried 10 times and there is no change, break out (~10 seconds)
            if (tryCount >= 20) break;

            // Give it a bit to execute
            await waitMs(500);

            // Re-fetch the chat with the updated information
            const chats = await Server().iMessageRepo.getChats({ chatGuid: theChat.guid, withParticipants: false });
            theChat = chats[0] ?? theChat;

            // Save the new name
            newName = theChat.displayName;
            if (newName !== prevName) break;
        }

        // Check if the name changed
        if (newName === prevName) {
            throw new Error("Failed to set new display name! Operation took longer than 5 seconds!");
        }

        return theChat;
    }

    static async create(addresses: string[], message: string): Promise<Chat> {
        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (addresses.length === 0) {
            throw new Error("No addresses provided!");
        }

        // Sanitize the addresses
        const theAddrs = addresses.map(e => slugifyAddress(e));
        const result = await Server().privateApiHelper.createChat(theAddrs, message);
        if (!result?.identifier) {
            throw new Error("Failed to create chat! Invalid transaction response!");
        }

        // Fetch the chat based on the return data
        let chats = await Server().iMessageRepo.getChats({ chatGuid: result.identifier, withParticipants: true });
        let tryCount = 0;
        while (chats.length === 0) {
            tryCount += 1;

            // If we've tried 10 times and there is no change, break out (~10 seconds)
            if (tryCount >= 20) break;

            // Give it a bit to execute
            await waitMs(500);

            // Re-fetch the chat with the updated information
            chats = await Server().iMessageRepo.getChats({ chatGuid: result.identifier, withParticipants: true });
        }

        // Check if the name changed
        if (chats.length === 0) {
            throw new Error("Failed to create new chat! Chat not found after 5 seconds!");
        }

        return chats[0];
    }

    static async toggleParticipant(chat: Chat, address: string, action: "add" | "remove"): Promise<Chat> {
        let theChat = chat;
        const prevCount = chat.participants.length;
        let newCount = chat.participants.length;

        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (chat.participants.length === 1) {
            throw new Error("Chat is not a group chat!");
        }

        await Server().privateApiHelper.toggleParticipant(theChat.guid, address, action);

        let tryCount = 0;
        while (newCount === prevCount) {
            tryCount += 1;

            // If we've tried 10 times and there is no change, break out (~10 seconds)
            if (tryCount >= 20) break;

            // Give it a bit to execute
            await waitMs(500);

            // Re-fetch the chat with the updated information
            const chats = await Server().iMessageRepo.getChats({ chatGuid: theChat.guid, withParticipants: true });
            theChat = chats[0] ?? theChat;

            // Save the new name
            newCount = theChat.participants.length;
            if (newCount !== prevCount) break;
        }

        // Check if the name changed
        if (newCount === prevCount) {
            throw new Error("Failed to set new display name! Operation took longer than 5 seconds!");
        }

        return theChat;
    }
}
