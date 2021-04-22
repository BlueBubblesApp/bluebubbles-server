import { ChatSpec, MessageSpec, HandleSpec, AttachmentSpec } from "@server/plugins/messages_db/types";

import { Chat } from "../entity/Chat";
import { Handle } from "../entity/Handle";
import { Attachment } from "../entity/Attachment";
import { Message } from "../entity/Message";

export const chatToSpec = (chat: Chat): ChatSpec => {
    return {
        originalROWID: chat.ROWID,
        guid: chat.guid,
        style: chat.style,
        state: chat.state,
        chatIdentifier: chat.chatIdentifier,
        service: chat.serviceName,
        roomName: chat.roomName,
        isArchived: chat.isArchived,
        displayName: chat.displayName,
        groupId: chat.groupId,
        isFiltered: chat.isFiltered,

        // Relationships
        participants: (chat.participants ?? []).map(item => handleToSpec(item)),
        messages: (chat.messages ?? []).map(item => messageToSpec(item))
    };
};

export const handleToSpec = (handle: Handle): HandleSpec => {
    return {
        originalROWID: handle.ROWID,
        address: handle.id,
        country: handle.country,
        service: handle.service,
        uncanonicalizedId: handle.uncanonicalizedId,

        // Relationships
        chats: (handle.chats ?? []).map(item => chatToSpec(item)),
        messages: (handle.messages ?? []).map(item => messageToSpec(item))
    };
};

export const attachmentToSpec = (attachment: Attachment): AttachmentSpec => {
    return {
        originalROWID: attachment.ROWID,
        guid: attachment.guid,
        createdDate: attachment.createdDate,
        startDate: attachment.startDate,
        originalPath: attachment.filePath,
        uti: attachment.uti,
        mimeType: attachment.mimeType,
        transferState: attachment.transferState,
        isOutgoing: attachment.isOutgoing,
        transferName: attachment.transferName,
        totalBytes: attachment.totalBytes,
        isSticker: attachment.isSticker ?? false,
        hideAttachment: attachment.hideAttachment ?? false,

        // Relationships
        messages: (attachment.messages ?? []).map(item => messageToSpec(item))
    };
};

export const messageToSpec = (message: Message): MessageSpec => {
    return {
        originalROWID: message.ROWID,
        guid: message.guid,
        text: message.text,
        replace: message.replace,
        serviceCenter: message.serviceCenter,
        originalHandleId: message.handleId,
        subject: message.subject,
        country: message.country,
        version: message.version,
        type: message.type,
        service: message.service,
        error: message.error,
        date: message.dateCreated,
        dateRead: message.dateRead,
        dateDelivered: message.dateDelivered,
        isFinished: message.isFinished,
        isEmote: message.isEmote,
        isFromMe: message.isFromMe,
        isEmpty: message.isEmpty,
        isDelayed: message.isDelayed,
        isAutoReply: message.isAutoReply,
        isPrepared: message.isPrepared,
        isRead: message.isRead,
        isSystemMessage: message.isSystemMessage,
        isSent: message.isSent,
        hasDdResults: message.hasDdResults,
        isServiceMessage: message.isServiceMessage,
        isForward: message.isForward,
        wasDowngraded: message.wasDowngraded,
        isArchive: message.isArchived,
        cacheHasAttachments: message.cacheHasAttachments,
        cacheRoomnames: message.cacheRoomnames,
        wasDataDetected: message.wasDataDetected,
        isAudioMessage: message.isAudioMessage,
        isPlayed: message.isPlayed,
        datePlayed: message.datePlayed,
        itemType: message.itemType,
        originalOtherHandle: message.otherHandle,
        groupTitle: message.groupTitle,
        groupActionType: message.groupActionType,
        shareStatus: message.shareStatus,
        shareDirection: message.shareDirection,
        isExpirable: message.isExpirable,
        messageActionType: message.messageActionType,
        messageSource: message.messageSource,
        associatedMessageGuid: message.associatedMessageGuid,
        associatedMessageType: message.associatedMessageType,
        balloonBundleId: message.balloonBundleId,
        payloadData: message.payloadData,
        expressiveSendStyleId: message.expressiveSendStyleId,
        associatedMessageRangeLocation: message.associatedMessageRangeLocation,
        associatedMessageRangeLength: message.associatedMessageRangeLength,
        timeExpressiveSendPlayed: message.timeExpressiveSendStyleId,

        // Relationships
        handle: message.handle ? handleToSpec(message.handle) : null,
        chats: (message.chats ?? []).map(item => chatToSpec(item)),
        attachments: (message.attachments ?? []).map(item => attachmentToSpec(item))
    };
};
