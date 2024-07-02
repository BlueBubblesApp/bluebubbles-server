import { EventCache } from "@server/eventCache";
import { MessageRepository } from "..";
import { Message } from "../entity/Message";
import { CHAT_READ_STATUS_CHANGED } from "@server/events";
import { Chat } from "../entity/Chat";
import { Loggable } from "@server/lib/logging/Loggable";

export type IMessagePollResult = {
    eventType: string;
    data: any;
};

export enum IMessagePollType {
    MESSAGE = "message",
    CHAT = "chat"
}

type MessageState = {
    dateCreated: number;
    isDelivered: boolean;
    dateDelivered: number;
    dateRead: number;
    dateEdited: number;
    dateRetracted: number;
    didNotifyRecipient: boolean;
    hasUnsentParts: boolean;
};

type ChatState = {
    cacheTime: number;
    lastReadMessageTimestamp: number;
};

export class IMessageCache {
    messageStates: Record<string, MessageState> = {};

    chatStates: Record<string, ChatState> = {};

    events: EventCache;

    constructor() {
        this.events = new EventCache();
    }

    trimCaches() {
        this.trimMessageStates();
        this.trimChatStates();
        this.trimEventCache();
    }

    private trimEventCache() {
        this.events.trim(1000 * 60 * 60);
    }

    private trimMessageStates() {
        const now = new Date().getTime();
        for (const guid in this.messageStates) {
            // Clear entries older than 1 hour
            if (this.messageStates[guid].dateCreated < now - 1000 * 60 * 60) {
                delete this.messageStates[guid];
            }
        }
    }

    private trimChatStates() {
        const now = new Date().getTime();
        for (const guid in this.chatStates) {
            // Clear entries older than 1 hour
            if (this.chatStates[guid].cacheTime < now - 1000 * 60 * 60) {
                delete this.chatStates[guid];
            }
        }
    
    }
}

export abstract class IMessagePoller extends Loggable {
    tag = "IMessagePoller";

    type: IMessagePollType;

    repo: MessageRepository;

    cache: IMessageCache;

    // Cache of the last state of the message that has been seen by a listener
    messageStates: Record<string, MessageState> = {};

    chatStates: Record<string, ChatState> = {};

    constructor(repo: MessageRepository, cache: IMessageCache) {
        super();

        this.repo = repo;
        this.cache = cache;
    }

    abstract poll(after: Date): Promise<IMessagePollResult[]>;

    getMessageEvent(message: Message): string | null {
        // If the GUID doesn't exist, it's a new message
        const guid = message.guid;
        if (!this.cache.events.find(guid)) return "new-entry";

        // If the GUID exists, check the date created.
        // If it doesn't exist, a race condition occurred and we should ignore it (return null)
        const state = this.messageStates[guid];
        if (!state) return null;

        // If any of the dates are newer, it's an update
        if (message.dateCreated.getTime() > state.dateCreated) return "updated-entry";

        const delivered = message?.dateDelivered ? message.dateDelivered.getTime() : 0;
        if (delivered > state.dateDelivered) return "updated-entry";

        if (message.isDelivered !== state.isDelivered) return "updated-entry";

        const read = message?.dateRead ? message.dateRead.getTime() : 0;
        if (read > state.dateRead) return "updated-entry";

        const edited = message?.dateEdited ? message.dateEdited.getTime() : 0;
        if (edited > state.dateEdited) return "updated-entry";

        const retracted = message?.dateRetracted ? message.dateRetracted.getTime() : 0;
        if (retracted > state.dateRetracted) return "updated-entry";

        // If the "notified" state changed, it's an update
        const didNotify = message.didNotifyRecipient ?? false;
        if (didNotify !== state.didNotifyRecipient) return "updated-entry";

        // If it has unsent parts, it's an update
        if (message.hasUnsentParts !== state.hasUnsentParts) return "updated-entry";

        return null;
    }

    processMessageEvent(message: Message): string | null {
        const event = this.getMessageEvent(message);
        if (!event) return null;

        if (event === "new-entry") {
            this.cache.events.add(message.guid);
        }

        this.messageStates[message.guid] = {
            dateCreated: message.dateCreated.getTime(),
            isDelivered: message.isDelivered ?? false,
            dateDelivered: message?.dateDelivered ? message.dateDelivered.getTime() : 0,
            dateRead: message?.dateRead ? message.dateRead.getTime() : 0,
            dateEdited: message.dateEdited ? message.dateEdited.getTime() : 0,
            dateRetracted: message.dateRetracted ? message.dateRetracted.getTime() : 0,
            didNotifyRecipient: message.didNotifyRecipient ?? false,
            hasUnsentParts: message.hasUnsentParts
        };

        return event;
    }

    getChatEvent(chat: Chat, defaultEvent = CHAT_READ_STATUS_CHANGED): string | null {
        // If the GUID doesn't exist, it's a new chat
        const guid = chat.guid;

        if (!this.cache.events.find(guid)) return defaultEvent;

        // If the GUID exists, check the date created.
        // If it doesn't exist, a race condition occurred and we should ignore it (return null)
        const state = this.chatStates[guid];
        if (!state) return null;

        const lastReadMessageTimestamp = chat.lastReadMessageTimestamp?.getTime() ?? 0;
        if (state.lastReadMessageTimestamp < lastReadMessageTimestamp) {
            return CHAT_READ_STATUS_CHANGED;
        }

        return null;
    }

    processChatEvent(chat: Chat, defaultEvent = CHAT_READ_STATUS_CHANGED): string | null {
        const event = this.getChatEvent(chat, defaultEvent);
        if (!event) return null;

        if (event === defaultEvent) {
            this.cache.events.add(chat.guid);
        }

        this.chatStates[chat.guid] = {
            cacheTime: new Date().getTime(),
            lastReadMessageTimestamp: chat.lastReadMessageTimestamp?.getTime() ?? 0
        };

        return event;
    }
}