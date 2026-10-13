import * as fs from "fs";
import { Chat } from "@server/databases/imessage/entity/Chat";
import {
    checkPrivateApiStatus,
    getiMessageAddressFormat,
    isEmpty,
    isNotEmpty,
    resultAwaiter
} from "@server/helpers/utils";
import {
    isMinBigSur,
    isMinVentura
} from "@server/env";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { ChatResponse } from "@server/types";
import { startChat } from "../apple/scripts";
import { MessageInterface } from "./messageInterface";
import { CHAT_READ_STATUS_CHANGED } from "@server/events";
import { ChatSerializer } from "../serializers/ChatSerializer";
import { Attachment } from "@server/databases/imessage/entity/Attachment";
import { Message } from "@server/databases/imessage/entity/Message";
import { MessageSerializer } from "../serializers/MessageSerializer";

export class ChatInterface {
    static async get({
        guid = null,
        withArchived = true,
        withLastMessage = false,
        offset = 0,
        limit = null,
        sort = "lastmessage"
    }: any = {}): Promise<[ChatResponse[], number]> {
        // First fetch chats without the last message.
        // This is because fetching the last message will make the participants list 1 for each chat.
        // It will also only return chats that have a last message.
        const [chats, totalChats] = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
            withLastMessage: false,
            withArchived,
            offset,
            limit
        });

        const lastMessageCache: { [key: string]: Message | null } = {};
        if (withLastMessage) {
            const [tmpChats, _] = await Server().iMessageRepo.getChats({
                chatGuid: guid as string,
                withLastMessage: true,
                withParticipants: false,
                withArchived,
                offset: null,
                limit: null
            });

            for (const chat of tmpChats) {
                lastMessageCache[chat.guid] = chat.messages.length > 0 ? chat.messages[0] : null;
            }
        }

        const results = [];
        for (const chat of chats ?? []) {
            const chatRes = await ChatSerializer.serialize({
                chat,
                config: { includeMessages: withLastMessage },
                messageConfig: {
                    parseAttributedBody: true,
                    parseMessageSummary: true,
                    parsePayloadData: true
                }
            });

            // Insert the lastmessage from the cache into the chat
            if (withLastMessage) {
                if (Object.keys(lastMessageCache).includes(chat.guid) && lastMessageCache[chat.guid]) {
                    chatRes.lastMessage = await MessageSerializer.serialize({
                        message: lastMessageCache[chat.guid] as Message
                    });
                } else {
                    chatRes.lastMessage = null;
                }
            }

            results.push(chatRes);
        }

        // If we have a sort parameter, handle the cases
        if (sort && sort === "lastmessage" && withLastMessage) {
            results.sort((a: ChatResponse, b: ChatResponse) => {
                const d1 = a.lastMessage?.dateCreated ?? a.lastMessage?.dateDelivered ?? 0;
                const d2 = b.lastMessage?.dateCreated ?? b.lastMessage?.dateDelivered ?? 0;
                if (d1 > d2) return -1;
                if (d1 < d2) return 1;
                return 0;
            });
        }

        return [results, totalChats];
    }

    static async setDisplayName(chat: Chat, displayName: string): Promise<Chat> {
        // If nothing changed, return the original chat
        const prevName = chat.displayName ?? '';
        if (prevName === displayName) {
            return chat;
        }

        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (chat.participants.length === 1) {
            throw new Error("Chat is not a group chat!");
        }

        await Server().privateApi.chat.setDisplayName(chat.guid, displayName);

        const maxWaitMs = 30000;
        const retChat = await resultAwaiter({
            maxWaitMs,
            getData: async (previousData: any | null) => {
                const [chats, _] = await Server().iMessageRepo.getChats({
                    chatGuid: chat.guid,
                    withParticipants: false
                });
                return chats[0] ?? previousData;
            },
            // Keep looping if the name is the same as before
            extraLoopCondition: data => {
                return (data?.displayName ?? '') === prevName;
            }
        });

        // Check if the name changed
        if (retChat?.displayName === prevName) {
            throw new Error(`Failed to set new display name! Operation took longer than ${maxWaitMs / 1000} seconds!`);
        }

        return retChat;
    }

    private static async createWithPrivateApi({
        addresses,
        message,
        service = "iMessage",
        attributedBody = null,
        subject = null,
        effectId = null
    }: {
        addresses: string[];
        message: string;
        service: "iMessage" | "SMS";
        attributedBody?: Record<string, any> | null;
        subject?: string;
        effectId?: string;
    }): Promise<Chat> {
        checkPrivateApiStatus();

        const result = await Server().privateApi.chat.create({
            addresses,
            message,
            service,
            attributedBody,
            subject,
            effectId
        });
        if (isEmpty(result.identifier)) {
            throw new Error("Failed to create chat via the Private API!");
        }

        const messageGuid = result.identifier;
        Server().log(`Verifying Chat creation for Message GUID: ${messageGuid}`, "debug");

        const maxWaitMs = 30000;
        const messageResult = await resultAwaiter({
            maxWaitMs,
            initialWaitMs: 500,
            getData: async _ => {
                // Get the message with the chat
                const message = await Server().iMessageRepo.getMessage(messageGuid, true);
                if (isEmpty(message?.chats)) return null;
                return message;
            },
            // Keep looping if we don't get any message back
            dataLoopCondition: data => {
                return isEmpty(data);
            }
        });

        // Check if the message can be found
        if (!messageResult) {
            throw new Error(`Failed to create new chat! Message not found after ${maxWaitMs / 1000} seconds!`);
        }

        // Get the chat from the message
        const chatGuid = messageResult.chats[0].guid;
        const [chats, _] = await Server().iMessageRepo.getChats({
            chatGuid,
            withParticipants: true
        });

        if (isEmpty(chats)) {
            throw new Error("Failed to create new chat! Chat not found!");
        }

        // Insert the message into the chat
        const chat = chats[0];
        messageResult.chats = [];
        chat.messages = [messageResult];
        return chat;
    }

    private static async createWithAppleScript({
        addresses,
        message,
        service = "iMessage",
        tempGuid = null
    }: {
        addresses: string[];
        message: string;
        service: "iMessage" | "SMS";
        tempGuid?: string | null;
    }): Promise<Chat> {
        let chatGuid: string;
        let sentMessage: Message;
        if (isMinBigSur) {
            // If we made it this far and this is Big Sur+, we know there is a message and 1 participant
            // Since chat creation doesn't work on Big Sur+, we just need to send the message to an
            // "infered" Chat GUID based on the service and first (only) address
            chatGuid = `${service};-;${addresses[0]}`;
            sentMessage = await MessageInterface.sendMessageSync({
                chatGuid,
                message,
                method: "apple-script",
                tempGuid
            });

            chatGuid = `${service};-;${getiMessageAddressFormat(addresses[0], true)}`;
        } else {
            const result = await FileSystem.executeAppleScript(startChat(addresses, service, null));
            Server().log(`StartChat AppleScript Returned: ${result}`, "debug");
            if (isEmpty(result) || (!result.includes(";-;") && !result.includes(";+;"))) {
                throw new Error("Failed to create chat! AppleScript did not return a Chat GUID!");
            }

            chatGuid = result.trim().split(" ").slice(-1)[0];
        }

        const maxWaitMs = 30000;
        const chats = await resultAwaiter({
            maxWaitMs,
            getData: async _ => {
                const [chats, __] = await Server().iMessageRepo.getChats({
                    chatGuid,
                    withParticipants: true
                });
                return chats;
            },
            // Keep looping if we don't get any chats back
            dataLoopCondition: data => {
                return isEmpty(data);
            }
        });

        // If we have a message, want to send via the private api, and are not on Big Sur, send the message
        if (isNotEmpty(message) && !isMinBigSur) {
            sentMessage = await MessageInterface.sendMessageSync({
                chatGuid,
                message,
                method: 'apple-script',
                tempGuid
            });
        }

        const chat = chats[0];
        if (sentMessage) {
            chat.messages = [sentMessage];
        }

        return chat;
    }

    static async create({
        addresses,
        message = null,
        method = "apple-script",
        service = "iMessage",
        tempGuid,
        attributedBody = null,
        subject = null,
        effectId = null
    }: {
        addresses: string[];
        message?: string | null;
        method?: "apple-script" | "private-api";
        service?: "iMessage" | "SMS";
        tempGuid?: string;
        attributedBody?: Record<string, any> | null;
        subject?: string;
        effectId?: string;
    }): Promise<Chat> {
        // Make sure we are executing this on a group chat
        if (isEmpty(addresses)) {
            throw new Error("No addresses provided!");
        }

        if (method == 'apple-script' && isMinBigSur && addresses.length > 1) {
            throw new Error("Cannot create group chats on macOS Big Sur or newer!");
        } else if (method == 'apple-script' && isMinBigSur && isEmpty(message)) {
            throw new Error("A message is required when creating chats on macOS Big Sur or newer!");
        } else if (method === "private-api" && isEmpty(message)) {
            throw new Error("A message is required when creating chats with the Private API!");
        }

        // Sanitize the addresses
        const theAddrs: string[] = addresses.map(e => getiMessageAddressFormat(e));
        if (method === "private-api") {
            return await ChatInterface.createWithPrivateApi({
                addresses: theAddrs,
                message,
                service,
                attributedBody,
                subject,
                effectId
            });
        } else {
            return await ChatInterface.createWithAppleScript({
                addresses: theAddrs,
                message,
                service,
                tempGuid
            });
        }
    }

    static async toggleParticipant(chat: Chat, address: string, action: "add" | "remove"): Promise<Chat> {
        const prevCount = (chat?.participants ?? []).length;
        checkPrivateApiStatus();

        // Make sure we are executing this on a group chat
        if (prevCount === 1) {
            throw new Error("Chat is not a group chat!");
        }

        Server().log(`Toggling Participant [Action: ${action}]: ${address}...`, "debug");
        await Server().privateApi.chat.toggleParticipant(chat.guid, address, action);

        const maxWaitMs = 30000;
        const retChat = await resultAwaiter({
            maxWaitMs,
            getData: async (previousData: any | null) => {
                const [chats, _] = await Server().iMessageRepo.getChats(
                    { chatGuid: chat.guid, withParticipants: true });
                return chats[0] ?? previousData;
            },
            // Keep looping if the participant count is the same as before
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
        if (!theChat) throw new Error(`Failed to delete chat! Chat not found. (GUID: ${guid})`);

        // Tell the private API to delete the chat
        await Server().privateApi.chat.delete(theChat.guid);

        // Wait for the DB changes to propogate
        const maxWaitMs = 30000;
        const success = await resultAwaiter({
            maxWaitMs,
            getData: async () => {
                const res = await repo.findOneBy({ guid: theChat.guid });
                return !res ? true : false;
            },
            // Keep looping if we keep finding the chat (getData returns false)
            dataLoopCondition: data => !data
        });

        if (!success) {
            throw new Error(`Failed to delete chat! Chat still exists. (GUID: ${theChat.guid})`);
        }
    }

    static async setGroupChatIcon(chat: Chat, iconPath: string | null): Promise<void> {
        checkPrivateApiStatus();
        if (!isMinBigSur) throw new Error("Setting group chat icons are only supported on macOS Big Sur or newer!");

        // The icon path can be null when unsetting the icon
        if (isNotEmpty(iconPath)) {
            if (!fs.existsSync(iconPath)) {
                throw new Error("Icon path does not exist!");
            }

            // Extract filename from path
            const filename = iconPath.split("/").pop();

            // Copy the file to the Messages Attachments folder
            iconPath = FileSystem.copyAttachment(iconPath, `${chat.chatIdentifier}-${filename}`, "private-api");
        }

        // Make sure we are executing this on a group chat
        if (chat.participants.length === 1) {
            throw new Error("Chat is not a group chat!");
        }

        // Change the chat icon
        await Server().privateApi.chat.setGroupChatIcon(chat.guid, iconPath);
    }

    static async getGroupChatIcon(chat: Chat): Promise<Attachment | null> {
        let iconGuid = null;
        for (const item of chat.properties ?? []) {
            if (isNotEmpty(item.groupPhotoGuid)) {
                iconGuid = item.groupPhotoGuid;
            }
        }

        if (isEmpty(iconGuid)) return null;

        // Find the corresponding attachment
        const attachment = await Server().iMessageRepo.getAttachment(iconGuid);
        if (!attachment) return null;

        // Return the attachment path
        return attachment;
    }

    static async leave({ chat, guid }: { chat?: Chat; guid?: string } = {}): Promise<void> {
        checkPrivateApiStatus();

        const repo = Server().iMessageRepo.db.getRepository(Chat);
        if (!chat && isEmpty(guid)) throw new Error("No chat or chat GUID provided!");

        const theChat = chat ?? (await repo.findOneBy({ guid }));
        if (!theChat) return;

        // Tell the private API to delete the chat
        await Server().privateApi.chat.leave(theChat.guid);
    }

    static async markRead(chatGuid: string): Promise<void> {
        await Server().privateApi.chat.markRead(chatGuid);
        await Server().emitMessage(CHAT_READ_STATUS_CHANGED, {
            chatGuid,
            read: true
        });
    }

    static async markUnread(chatGuid: string): Promise<void> {
        if (isMinVentura) {
            await Server().privateApi.chat.markUnread(chatGuid);
        }

        await Server().emitMessage(CHAT_READ_STATUS_CHANGED, {
            chatGuid,
            read: false
        });
    }

    static async startTyping(chatGuid: string): Promise<void> {
        checkPrivateApiStatus();
        await Server().privateApi.chat.startTyping(chatGuid);

        // Add the chat to the typing cache
        if (!Server().typingCache.includes(chatGuid)) {
            Server().typingCache.push(chatGuid);
        }
    }

    static async stopTyping(chatGuid: string): Promise<void> {
        checkPrivateApiStatus();
        await Server().privateApi.chat.stopTyping(chatGuid);
        
        // Remove the chat from the typing cache
        if (Server().typingCache.includes(chatGuid)) {
            Server().typingCache = Server().typingCache.filter(c => c !== chatGuid);
        }
    }

    static async deleteChatMessage(chat: Chat, message: Message): Promise<void> {
        await Server().privateApi.chat.deleteMessage(chat.guid, message.guid);
    }

    static async canShareContactInfo(chatGuid: string): Promise<boolean> {
        checkPrivateApiStatus();
        if (!isMinBigSur) throw new Error("Contact sharing is only supported on macOS Big Sur or newer!");
        const result = await Server().privateApi.chat.shouldOfferContactSharing(chatGuid);
        if (result?.data?.share == null) throw new Error("Failed to check if contact sharing is available!");
        return result.data.share;
    }

    static async shareContactInfo(chatGuid: string): Promise<void> {
        checkPrivateApiStatus();
        if (!isMinBigSur) throw new Error("Contact sharing is only supported on macOS Big Sur or newer!");
        await Server().privateApi.chat.shareContactCard(chatGuid);
    }
}
