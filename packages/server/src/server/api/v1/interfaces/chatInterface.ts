import { Chat, getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import {
    checkPrivateApiStatus,
    isEmpty,
    isMinBigSur,
    isNotEmpty,
    resultAwaiter,
    slugifyAddress
} from "@server/helpers/utils";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { ChatResponse, HandleResponse } from "@server/types";
import { startChat } from "../apple/scripts";
import { MessageInterface } from "./messageInterface";
import { CHAT_READ_STATUS_CHANGED } from "@server/events";

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
        const prevName = chat.displayName;
        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (chat.participants.length === 1) {
            throw new Error("Chat is not a group chat!");
        }

        await Server().privateApiHelper.setDisplayName(chat.guid, displayName);

        const maxWaitMs = 30000;
        const retChat = await resultAwaiter({
            maxWaitMs,
            getData: async (previousData: any | null) => {
                const chats = await Server().iMessageRepo.getChats({ chatGuid: chat.guid, withParticipants: false });
                return chats[0] ?? previousData;
            },
            extraLoopCondition: data => {
                if (!data) return false;
                return data?.displayName === prevName;
            }
        });

        // Check if the name changed
        if (retChat?.displayName === prevName) {
            throw new Error(`Failed to set new display name! Operation took longer than ${maxWaitMs / 1000} seconds!`);
        }

        return retChat;
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
        let chatGuid: string;
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

        const maxWaitMs = 30000;
        const chats = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                return await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
            },
            dataLoopCondition: data => {
                return isEmpty(data);
            }
        });

        // Check if the name changed
        if (isEmpty(chats)) {
            throw new Error(`Failed to create new chat! Chat not found after ${maxWaitMs / 1000} seconds!`);
        }

        // If we have a message, want to send via the private api, and are not on Big Sur, send the message
        if (isNotEmpty(message) && !isMinBigSur) {
            sentMessage = await MessageInterface.sendMessageSync({ chatGuid, message, method, tempGuid });
        }

        const chat = chats[0];
        if (sentMessage) {
            chat.messages = [sentMessage];
        }

        return chat;
    }

    static async toggleParticipant(chat: Chat, address: string, action: "add" | "remove"): Promise<Chat> {
        const prevCount = (chat?.participants ?? []).length;
        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (prevCount === 1) {
            throw new Error("Chat is not a group chat!");
        }

        Server().log(`Toggling Participant [Action: ${action}]: ${address}...`, "debug");
        await Server().privateApiHelper.toggleParticipant(chat.guid, address, action);

        const maxWaitMs = 30000;
        const retChat = await resultAwaiter({
            maxWaitMs,
            getData: async (previousData: any | null) => {
                const chats = await Server().iMessageRepo.getChats({ chatGuid: chat.guid, withParticipants: true });
                return chats[0] ?? previousData;
            },
            dataLoopCondition: data => {
                return (data?.participants ?? []).length === prevCount;
            }
        });

        // Check if the name changed
        if ((retChat?.participants ?? []).length === prevCount) {
            throw new Error(`Failed to ${action} participant to chat! Operation took longer than 5 seconds!`);
        }

        return retChat;
    }

    static async delete({ chat, guid }: { chat?: Chat; guid?: string } = {}): Promise<void> {
        checkPrivateApiStatus();

        const repo = Server().iMessageRepo.db.getRepository(Chat);
        if (!chat && isEmpty(guid)) throw new Error("No chat or chat GUID provided!");

        const theChat = chat ?? (await repo.findOneBy({ guid }));
        if (!theChat) return;

        // Tell the private API to delete the chat
        await Server().privateApiHelper.deleteChat(theChat.guid);

        // Wait for the DB changes to propogate
        const maxWaitMs = 30000;
        const success = !!(await resultAwaiter({
            maxWaitMs,
            getData: async () => {
                return await repo.findOneBy({ guid: theChat.guid });
            },
            // Loop until we don't have data (chat is deleted)
            dataLoopCondition: data => !!data
        }));

        if (!success) {
            throw new Error(`Failed to delete chat! Chat still exists. (GUID: ${theChat.guid})`);
        }
    }

    static async markRead(chatGuid: string): Promise<void> {
        await Server().privateApiHelper.markChatRead(chatGuid);
        await Server().emitMessage(CHAT_READ_STATUS_CHANGED, {
            chatGuid,
            read: true
        });
    }

    static async markUnread(chatGuid: string): Promise<void> {
        await Server().privateApiHelper.markChatUnread(chatGuid);
        await Server().emitMessage(CHAT_READ_STATUS_CHANGED, {
            chatGuid,
            read: false
        });
    }
}
