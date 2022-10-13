import { Server } from "@server";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getHandleResponse } from "@server/databases/imessage/entity/Handle";
import { isEmpty, isMinHighSierra, isMinVentura, isNotEmpty } from "@server/helpers/utils";
import { HandleResponse, MessageResponse } from "@server/types";
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
        maxSizeBytes = 4000,
        isForNotification = false
    }: MessageSerializerSingleParams): Promise<MessageResponse> {
        return (
            await MessageSerializer.serializeList({
                messages: [message],
                attachmentConfig,
                parseAttributedBody,
                parseMessageSummary,
                loadChatParticipants,
                enforceMaxSize,
                maxSizeBytes,
                isForNotification
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
        maxSizeBytes = 4000,
        isForNotification = false
    }: MessageSerializerParams): Promise<MessageResponse[]> {
        // Convert the messages to their serialized versions
        const messageResponses: MessageResponse[] = [];
        for (const message of messages) {
            messageResponses.push(
                await MessageSerializer.convert({
                    message: message,
                    attachmentConfig,
                    loadChatParticipants,
                    isForNotification
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

        // The parse options are enforced _after_ the convert function is called.
        // This is so that we can properly extract the text from the attributed body
        // for those on macOS Ventura. Otherwise, set it to null to not clutter the payload.
        if (!parseAttributedBody || !parseMessageSummary) {
            for (let i = 0; i < messageResponses.length; i++) {
                if (!parseAttributedBody && "attributedBody" in messageResponses[i]) {
                    messageResponses[i].attributedBody = null;
                }

                if (!parseMessageSummary && "messageSummaryInfo" in messageResponses[i]) {
                    messageResponses[i].messageSummaryInfo = null;
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

        return messageResponses;
    }

    private static async convert({
        message,
        attachmentConfig = {
            convert: true,
            getData: false,
            loadMetadata: true
        },
        isForNotification = false
    }: MessageSerializerSingleParams): Promise<MessageResponse> {
        let output = {
            originalROWID: message.ROWID,
            guid: message.guid,
            text: message.universalText(true),
            attributedBody: message.attributedBody,
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
            error: message.error,
            dateCreated: message.dateCreated ? message.dateCreated.getTime() : null,
            dateRead: message.dateRead ? message.dateRead.getTime() : null,
            dateDelivered: message.dateDelivered ? message.dateDelivered.getTime() : null,
            isFromMe: message.isFromMe,
            isArchived: message.isArchived,
            itemType: message.itemType,
            groupTitle: message.groupTitle,
            groupActionType: message.groupActionType,
            balloonBundleId: message.balloonBundleId,
            associatedMessageGuid: message.associatedMessageGuid,
            associatedMessageType: message.associatedMessageType,
            expressiveSendStyleId: message.expressiveSendStyleId,
            threadOriginatorGuid: message.threadOriginatorGuid
        };

        if (!isForNotification) {
            output = {
                ...output,
                ...{
                    country: message.country,
                    isDelayed: message.isDelayed,
                    isAutoReply: message.isAutoReply,
                    isSystemMessage: message.isSystemMessage,
                    isServiceMessage: message.isServiceMessage,
                    isForward: message.isForward,
                    threadOriginatorPart: message.threadOriginatorPart,
                    isCorrupt: message.isCorrupt,
                    datePlayed: message.datePlayed ? message.datePlayed.getTime() : null,
                    cacheRoomnames: message.cacheRoomnames,
                    isSpam: message.isSpam,
                    isExpired: message.isExpirable,
                    hasDdResults: message.hasDdResults,
                    timeExpressiveSendStyleId: message.timeExpressiveSendStyleId
                        ? message.timeExpressiveSendStyleId.getTime()
                        : null,
                    isAudioMessage: message.isAudioMessage,
                    replyToGuid: message.replyToGuid
                }
            };
        }

        if (isMinHighSierra) {
            output = {
                ...output,
                ...{
                    messageSummaryInfo: message.messageSummaryInfo
                }
            };
        }

        if (isMinVentura) {
            output = {
                ...output,
                ...{
                    dateEdited: message.dateEdited ? message.dateEdited.getTime() : null,
                    dateRetracted: message.dateRetracted ? message.dateRetracted.getTime() : null,
                    partCount: message.partCount
                }
            };
        }

        return output;
    }
}
