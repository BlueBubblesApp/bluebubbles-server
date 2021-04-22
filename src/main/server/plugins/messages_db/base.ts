import { PluginBase } from "@server/plugins/base";
import { EventEmitter } from "events";
import {
    ChatSpec,
    MessageSpec,
    AttachmentSpec,
    HandleSpec,
    GetChatsParams,
    GetAttachmentsParams,
    GetHandlesParams,
    GetMessagesParams
} from "./types";

interface MessagesDbPluginBase {
    setup?(): Promise<void>;
    connect(): Promise<void>;
    disconnect(): Promise<void>;

    // Chat funcs
    getChats?(params: GetChatsParams): Promise<ChatSpec[]>;
    getChat?(guid: string, params: GetChatsParams): Promise<ChatSpec>;
    getChatMessages?(guid: string, params: GetMessagesParams): Promise<MessageSpec[]>;
    getChatLastMessage?(guid: string): Promise<MessageSpec>;
    getChatParticipants?(guid: string): Promise<HandleSpec[]>;

    // Attachment funcs
    getAttachments?(params: GetAttachmentsParams): Promise<AttachmentSpec[]>;
    getAttachment?(guid: string, params: GetAttachmentsParams): Promise<AttachmentSpec>;

    // Handle funcs
    getHandles?(params: GetHandlesParams): Promise<HandleSpec[]>;
    getHandle?(address: string, params: GetHandlesParams): Promise<HandleSpec>;

    // Messages funcs
    getMessages?(params: GetMessagesParams): Promise<MessageSpec[]>;
    getMessageAttachments?(guid: string, params: GetAttachmentsParams): Promise<AttachmentSpec>;
    getUpdatedMessages?(params: GetMessagesParams): Promise<MessageSpec[]>;

    // Some analytics routes
    getTotalMessagesForChat?(guid: string): Promise<number>;
    getTotalMessages?(): Promise<number>;
    getTotalAttachmentsForChat?(guid: string): Promise<number>;
    getTotalImagesForChat?(guid: string): Promise<number>;
    getTotalVideosForChat?(guid: string): Promise<number>;
}

class MessagesDbPluginBase extends PluginBase {
    async startup() {
        if (this.setup) await this.setup();
        await this.connect();
    }

    async shutdown() {
        await this.disconnect();
    }
}

export { MessagesDbPluginBase };
