import { Chat, getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import { checkPrivateApiStatus, isEmpty, isMinBigSur, isNotEmpty, slugifyAddress, waitMs } from "@server/helpers/utils";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { ChatResponse, HandleResponse } from "@server/types";
import { startChat } from "../apple/scripts";
import { MessageInterface } from "./messageInterface";

export class ChatInterface {
    static async get({
        guid = null,
        withArchived = true,
        withLastMessage = false,
        offset = 0,
        limit = null,
        sort = "lastmessage"
    }: any = {}): Promise<ChatResponse[]> {
        const chats = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
            withParticipants: false,
            withLastMessage,
            withArchived,
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
            const chatRes = await getChatResponse(chat);

            // Insert the cached participants from the original request
            if (Object.keys(chatCache).includes(chat.guid)) {
                chatRes.participants = await Promise.all(
                    chatCache[chat.guid].map(async (e): Promise<HandleResponse> => {
                        const test = await getHandleResponse(e);
                        return test;
                    })
                );
            }

            if (withLastMessage) {
                // Set the last message, if applicable
                if (isNotEmpty(chatRes.messages)) {
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

    static async create({
        addresses,
        message = null,
        method = "apple-script",
        service = "iMessage",
        tempGuid
    }: {
        addresses: string[];
        message?: string | null;
        method?: "apple-script" | "private-api";
        service?: "iMessage" | "SMS";
        tempGuid?: string;
    }): Promise<Chat> {
        // Big sur can't use the private api to send
        if (!isMinBigSur && method === "private-api") checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (isEmpty(addresses)) {
            throw new Error("No addresses provided!");
        }

        if (isMinBigSur && addresses.length > 1) {
            throw new Error("Cannot create group chats on macOS Big Sur or newer!");
        } else if (isMinBigSur && isEmpty(message)) {
            throw new Error("A message is required when creating chats on macOS Big Sur or newer!");
        }

        // Sanitize the addresses
        const theAddrs = addresses.map(e => slugifyAddress(e));
        let chatGuid;
        let sentMessage;
        if (isMinBigSur) {
            // If we made it this far and this is Big Sur+, we know there is a message and 1 participant
            // Since chat creation doesn't work on Big Sur+, we just need to send the message to an
            // "infered" Chat GUID based on the service and first (only) address
            chatGuid = `${service};-;${theAddrs[0]}`;
            sentMessage = await MessageInterface.sendMessageSync({
                chatGuid,
                message,
                method: "apple-script",
                tempGuid
            });
        } else {
            const result = await FileSystem.executeAppleScript(startChat(theAddrs, service, null));
            Server().log(`StartChat AppleScript Returned: ${result}`, "debug");
            if (isEmpty(result) || (!result.includes(";-;") && !result.includes(";+;"))) {
                throw new Error("Failed to create chat! AppleScript did not return a Chat GUID!");
            }

            chatGuid = result.trim().split(" ").slice(-1)[0];
        }

        // Fetch the chat based on the return data
        Server().log(`Verifying Chat creation for GUID: ${chatGuid}`, "debug");
        let chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
        let tryCount = 0;
        while (isEmpty(chats)) {
            tryCount += 1;

            // If we've tried 10 times and there is no change, break out (~10 seconds)
            if (tryCount >= 20) break;

            // Give it a bit to execute
            await waitMs(500);

            // Re-fetch the chat with the updated information
            chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
        }

        // Check if the name changed
        if (isEmpty(chats)) {
            throw new Error("Failed to create new chat! Chat not found after 5 seconds!");
        }

        // If we have a message, want to send via the private api, and are not on Big Sur, send the message
        if (isNotEmpty(message) && !isMinBigSur) {
            sentMessage = await MessageInterface.sendMessageSync({ chatGuid, message, method, tempGuid });
        }

        const chat = chats[0];
        chat.messages = [sentMessage];
        return chat;
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

        Server().log(`Toggling Participant [Action: ${action}]: ${address}...`, "debug");
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

    static async delete({ chat, guid }: { chat?: Chat; guid?: string } = {}): Promise<void> {
        checkPrivateApiStatus();

        const repo = Server().iMessageRepo.db.getRepository(Chat);
        if (!chat && isEmpty(guid)) throw new Error("No chat or chat GUID provided!");

        const theChat = chat ?? (await repo.findOneBy({ guid }));
        if (!theChat) return;

        // Tell the private API to delete the chat
        await Server().privateApiHelper.deleteChat(theChat.guid);

        let tryCount = 0;
        let success = false;
        while (tryCount < 10) {
            tryCount += 1;

            // See if the chat exists in the DB
            const chat = await repo.findOneBy({ guid: theChat.guid });

            // If it doesn't, we're all good and can break out. It's been deleted.
            // Otherwise, we need to check again after our wait time
            if (!chat) {
                success = true;
                break;
            }

            // Give it a bit to execute
            await waitMs(500);
        }

        if (!success) {
            throw new Error(`Failed to delete chat! Chat still exists. (GUID: ${theChat.guid})`);
        }
    }
}
