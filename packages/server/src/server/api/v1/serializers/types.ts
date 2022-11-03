import type { Attachment } from "@server/databases/imessage/entity/Attachment";
import type { Chat } from "@server/databases/imessage/entity/Chat";
import type { Message } from "@server/databases/imessage/entity/Message";
import type { Handle } from "@server/databases/imessage/entity/Handle";

export interface AttachmentSerializerParams {
    convert?: boolean;
    loadMetadata?: boolean;
    loadData?: boolean;
    includeMessageGuids?: boolean;
}

export interface ChatSerializerParams {
    includeParticipants?: boolean;
    includeMessages?: boolean;
}

export interface HandleSerializerParams {
    includeChats?: boolean;
    includeMessages?: boolean;
}

export interface MessageSerializerParams {
    parseAttributedBody?: boolean;
    parseMessageSummary?: boolean;
    parsePayloadData?: boolean;
    includeChats?: boolean;
    loadChatParticipants?: boolean;
    enforceMaxSize?: boolean;
    maxSizeBytes?: number;
}

export interface MessageSerializerSingleParams {
    message: Message;
    config?: MessageSerializerParams;
    attachmentConfig?: AttachmentSerializerParams;
    isForNotification?: boolean;
}

export interface MessageSerializerMultiParams {
    messages: Message[];
    config?: MessageSerializerParams;
    attachmentConfig?: AttachmentSerializerParams;
    isForNotification?: boolean;
}

export interface AttachmentSerializerSingleParams {
    attachment: Attachment;
    config?: AttachmentSerializerParams;
    messageConfig?: MessageSerializerParams;
    isForNotification?: boolean;
}

export interface AttachmentSerializerMultiParams {
    attachments: Attachment[];
    config?: AttachmentSerializerParams;
    messageConfig?: MessageSerializerParams;
    isForNotification?: boolean;
}

export interface ChatSerializerSingleParams {
    chat: Chat;
    config?: ChatSerializerParams;
    messageConfig?: MessageSerializerParams;
    handleConfig?: HandleSerializerParams;
    isForNotification?: boolean;
}

export interface ChatSerializerMutliParams {
    chats: Chat[];
    config?: ChatSerializerParams;
    messageConfig?: MessageSerializerParams;
    handleConfig?: HandleSerializerParams;
    isForNotification?: boolean;
}

export interface HandleSerializerSingleParams {
    handle: Handle;
    config?: HandleSerializerParams;
    messageConfig?: MessageSerializerParams;
    chatConfig?: ChatSerializerParams;
    isForNotification?: boolean;
}

export interface HandleSerializerMutliParams {
    handles: Handle[];
    config?: HandleSerializerParams;
    messageConfig?: MessageSerializerParams;
    chatConfig?: ChatSerializerParams;
    isForNotification?: boolean;
}
