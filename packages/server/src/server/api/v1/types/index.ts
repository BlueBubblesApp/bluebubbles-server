import type { Message } from "@server/databases/imessage/entity/Message";
import type { ValidRemoveTapback, ValidTapback } from "@server/types";

export type SendMessageParams = {
    chatGuid: string;
    message: string;
    method: "apple-script" | "private-api";
    attributedBody?: Record<string, any> | null;
    subject?: string;
    effectId?: string;
    selectedMessageGuid?: string;
    tempGuid?: string;
    partIndex?: number;
};

export type SendMessagePrivateApiParams = {
    chatGuid: string;
    message: string;
    attributedBody?: Record<string, any> | null;
    subject?: string;
    effectId?: string;
    selectedMessageGuid?: string;
    partIndex?: number;
};

export type UnsendMessageParams = {
    chatGuid: string;
    messageGuid: string;
    partIndex: number;
};

export type EditMessageParams = {
    chatGuid: string;
    messageGuid: string;
    editedMessage: string;
    backwardsCompatMessage: string;
    partIndex: number;
};

export type SendAttachmentParams = {
    chatGuid: string;
    attachmentPath: string;
    attachmentName?: string;
    attachmentGuid?: string;
};

export type SendReactionParams = {
    chatGuid: string;
    message: Message;
    reaction: ValidTapback | ValidRemoveTapback;
    tempGuid?: string | null;
    partIndex?: number | null;
};
