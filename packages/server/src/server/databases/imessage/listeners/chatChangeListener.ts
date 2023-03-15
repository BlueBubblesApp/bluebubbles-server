import { Chat } from "../entity/Chat";
import { CHAT_READ_STATUS_CHANGED } from "@server/events";
import { ChangeListener } from "./changeListener";

type ChatState = {
    cacheTime: number;
    lastReadMessageTimestamp: number;
};

export abstract class ChatChangeListener extends ChangeListener {
    // Cache of the last state of the chats that has been seen by a listener
    cacheState: Record<string, ChatState> = {};

    checkCache() {
        // Purge emitted chats if it gets above 250 items
        // 250 is pretty arbitrary at this point...
        if (this.cache.size() > 250) {
            if (this.cache.size() > 0) {
                this.cache.purge();
            }
        }

        // Purge anything from the cache where the date created is > 5 minutes old
        const now = new Date().getTime();
        const fiveMinutesAgo = now - 5 * 60 * 1000;
        for (const key in this.cacheState) {
            if (this.cacheState[key].cacheTime < fiveMinutesAgo) {
                delete this.cacheState[key];
            }
        }
    }

    getChatEvent(chat: Chat, defaultEvent = CHAT_READ_STATUS_CHANGED): string | null {
        // If the GUID doesn't exist, it's a new chat
        const guid = chat.guid;

        if (!this.cache.find(guid)) return defaultEvent;

        // If the GUID exists, check the date created.
        // If it doesn't exist, a race condition occurred and we should ignore it (return null)
        const state = this.cacheState[guid];
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
            this.cache.add(chat.guid);
        }

        this.cacheState[chat.guid] = {
            cacheTime: new Date().getTime(),
            lastReadMessageTimestamp: chat.lastReadMessageTimestamp?.getTime() ?? 0
        };

        return event;
    }
}
