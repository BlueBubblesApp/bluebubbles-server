import { Server } from "@server";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse } from "@server/databases/imessage/entity/Handle";
import { isEmpty, isNotEmpty, sanitizeStr } from "@server/helpers/utils";
import { HandleResponse, MessageResponse } from "@server/types";
import { AttributedBodyUtils } from "@server/utils/AttributedBodyUtils";
import type { MessageSerializerParams, MessageSerializerSingleParams } from "./types";

export class MessageSerializer {
    static async serialize({
        message,
        attachmentConfig = {
            convert: true,
            getData: false,
            loadMetadata: true
        },
        parseAttributedBody = false,
        parseMessageSummary = false,
        loadChatParticipants = true,
        enforceMaxSize = false,
        // Max payload size is 4000 bytes
        // https://firebase.google.com/docs/cloud-messaging/concept-options#notifications_and_data_messages
        maxSizeBytes = 4000
    }: MessageSerializerSingleParams): Promise<MessageResponse> {
        return (
            await MessageSerializer.serializeList({
                messages: [message],
                attachmentConfig,
                parseAttributedBody,
                parseMessageSummary,
                loadChatParticipants,
                enforceMaxSize,
                maxSizeBytes
            })
        )[0];
    }

    static async serializeList({
        messages,
        attachmentConfig = {
            convert: true,
            getData: false,
            loadMetadata: true
        },
        parseAttributedBody = false,
        parseMessageSummary = false,
        loadChatParticipants = true,
        enforceMaxSize = false,
        maxSizeBytes = 4000
    }: MessageSerializerParams): Promise<MessageResponse[]> {
        // Convert the messages to their serialized versions
        const messageResponses: MessageResponse[] = [];
        for (const message of messages) {
            messageResponses.push(
                await MessageSerializer.convert({
                    message: message,
                    attachmentConfig,
                    parseAttributedBody,
                    parseMessageSummary,
                    loadChatParticipants
                })
            );
        }

        // Handle fetching the chat participants with the messages (if requested)
        const chatCache: { [key: string]: HandleResponse[] } = {};
        if (loadChatParticipants) {
            for (let i = 0; i < messages.length; i++) {
                // If there aren't any chats for this message, skip it
                if (isEmpty(messages[i]?.chats ?? [])) continue;

                // Iterate over the chats for this message and load the participants.
                // We only need to load the participants for group chats since DMs don't have them.
                // Once we load the chat participants for a chat, we will cache it to be used later.
                for (let k = 0; k < (messages[i]?.chats ?? []).length; i++) {
                    // If it's not a group, skip it (style == 43; DM = 45)
                    // Also skip it if there are already participants
                    if (messages[i]?.chats[k].style !== 43 || isNotEmpty(messages[i]?.chats[k].participants)) continue;

                    // Get the participants for this chat, or load it from our cache
                    if (!Object.keys(chatCache).includes(messages[i]?.chats[k].guid)) {
                        const chats = await Server().iMessageRepo.getChats({
                            chatGuid: messages[i]?.chats[k].guid,
                            withParticipants: true
                        });
                        if (isNotEmpty(chats)) {
                            chatCache[messages[i]?.chats[k].guid] = await Promise.all(
                                (chats[0].participants ?? []).map(async p => await getHandleResponse(p))
                            );
                            messageResponses[i].chats[k].participants = chatCache[messages[i]?.chats[k].guid];
                        }
                    } else {
                        messageResponses[i].chats[k].participants = chatCache[messages[i].chats[k].guid];
                    }
                }
            }
        }

        if (enforceMaxSize) {
            const strData = JSON.stringify(messageResponses);
            const len = Buffer.byteLength(strData, "utf8");

            // If we've reached out max size, we need to clear the participants
            if (len > maxSizeBytes) {
                for (let i = 0; i < messageResponses.length; i++) {
                    for (let c = 0; c < (messageResponses[i]?.chats ?? []).length; c++) {
                        if (isEmpty(messageResponses[i].chats[c].participants)) continue;
                        messageResponses[i].chats[c].participants = [];
                    }
                }
            }
        }

        // For Ventura, we need to check for the text message within the attributed body, so we can use it as the text.
        // It will be null/empty on Ventura.
        for (let i = 0; i < messageResponses.length; i++) {
            const msgText = sanitizeStr(messageResponses[i].text ?? "");
            const bodyText = AttributedBodyUtils.extractText(messageResponses[i].attributedBody);
            if (isEmpty(msgText) && isNotEmpty(bodyText)) {
                messageResponses[i].text = sanitizeStr(bodyText);
            }
        }

        return messageResponses;
    }

    private static async convert({
        message,
        parseAttributedBody = false,
        parseMessageSummary = false,
        attachmentConfig = {
            convert: true,
            getData: false,
            loadMetadata: true
        }
    }: MessageSerializerSingleParams): Promise<MessageResponse> {
        return {
            originalROWID: message.ROWID,
            guid: message.guid,
            text: message.text,
            attributedBody: parseAttributedBody ? message.attributedBody : null,
            messageSummaryInfo: parseMessageSummary ? message.messageSummaryInfo : null,
            handle: message.handle ? await getHandleResponse(message.handle) : null,
            handleId: message.handleId,
            otherHandle: message.otherHandle,
            chats: await Promise.all((message.chats ?? []).map(chat => getChatResponse(chat))),
            attachments: await Promise.all(
                (message.attachments ?? []).map(a =>
                    getAttachmentResponse(a, {
                        convert: attachmentConfig.convert,
                        getData: attachmentConfig.getData,
                        loadMetadata: attachmentConfig.loadMetadata
                    })
                )
            ),
            subject: message.subject,
            country: message.country,
            error: message.error,
            dateCreated: message.dateCreated ? message.dateCreated.getTime() : null,
            dateRead: message.dateRead ? message.dateRead.getTime() : null,
            dateDelivered: message.dateDelivered ? message.dateDelivered.getTime() : null,
            isFromMe: message.isFromMe,
            isDelayed: message.isDelayed,
            isAutoReply: message.isAutoReply,
            isSystemMessage: message.isSystemMessage,
            isServiceMessage: message.isServiceMessage,
            isForward: message.isForward,
            isArchived: message.isArchived,
            cacheRoomnames: message.cacheRoomnames,
            isAudioMessage: message.isAudioMessage,
            hasDdResults: message.hasDdResults,
            datePlayed: message.datePlayed ? message.datePlayed.getTime() : null,
            itemType: message.itemType,
            groupTitle: message.groupTitle,
            groupActionType: message.groupActionType,
            isExpired: message.isExpirable,
            balloonBundleId: message.balloonBundleId,
            associatedMessageGuid: message.associatedMessageGuid,
            associatedMessageType: message.associatedMessageType,
            expressiveSendStyleId: message.expressiveSendStyleId,
            timeExpressiveSendStyleId: message.timeExpressiveSendStyleId
                ? message.timeExpressiveSendStyleId.getTime()
                : null,
            replyToGuid: message.replyToGuid,
            isCorrupt: message.isCorrupt,
            isSpam: message.isSpam,
            threadOriginatorGuid: message.threadOriginatorGuid,
            threadOriginatorPart: message.threadOriginatorPart,
            dateEdited: message.dateEdited ? message.dateEdited.getTime() : null,
            dateRetracted: message.dateRetracted ? message.dateRetracted.getTime() : null,
            partCount: message.partCount
        };
    }
}
