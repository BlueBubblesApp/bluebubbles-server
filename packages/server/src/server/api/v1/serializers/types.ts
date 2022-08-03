import type { Message } from "@server/databases/imessage/entity/Message";

export interface AttachmentConfigParams {
    convert?: boolean;
    loadMetadata?: boolean;
    getData?: boolean;
}

export interface MessageSerializerSingleParams {
    message: Message;
    attachmentConfig?: AttachmentConfigParams;
    parseAttributedBody?: boolean;
    loadChatParticipants?: boolean;
}

export interface MessageSerializerParams {
    messages: Message[];
    attachmentConfig?: AttachmentConfigParams;
    parseAttributedBody?: boolean;
    loadChatParticipants?: boolean;
}
