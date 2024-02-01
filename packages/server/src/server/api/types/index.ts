import type { Message } from "@server/databases/imessage/entity/Message";
import type { ValidRemoveTapback, ValidTapback } from "@server/types";
import * as net from "net";

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
    ddScan?: boolean;
};

export type SendMessagePrivateApiParams = {
    chatGuid: string;
    message: string;
    attributedBody?: Record<string, any> | null;
    subject?: string;
    effectId?: string;
    selectedMessageGuid?: string;
    partIndex?: number;
    ddScan?: boolean;
};

export type SendAttachmentPrivateApiParams = {
    chatGuid: string;
    filePath: string;
    isAudioMessage?: boolean;
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
    method?: string;
    attachmentPath: string;
    attachmentName?: string;
    attachmentGuid?: string;
    isAudioMessage?: boolean;
    attributedBody?: Record<string, any> | null;
    subject?: string;
    effectId?: string;
    selectedMessageGuid?: string;
    partIndex?: number;
};

export type SendReactionParams = {
    chatGuid: string;
    message: Message;
    reaction: ValidTapback | ValidRemoveTapback;
    tempGuid?: string | null;
    partIndex?: number | null;
};

export type SendMultipartTextParams = {
    chatGuid: string;
    isAudioMessage?: boolean;
    attributedBody?: Record<string, any> | null;
    subject?: string;
    effectId?: string;
    selectedMessageGuid?: string;
    partIndex?: number;
    parts: Record<string, any>[];
    ddScan?: boolean;
};

export class Socket extends net.Socket {
    id: string;
}
