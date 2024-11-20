import { Server } from "@server";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { isMinHighSierra, isMinMonterey, isMinVentura } from "@server/env";
import { HandleResponse, MessageResponse } from "@server/types";
import { AttachmentSerializer } from "./AttachmentSerializer";
import { ChatSerializer } from "./ChatSerializer";
import { DEFAULT_ATTACHMENT_CONFIG, DEFAULT_MESSAGE_CONFIG } from "./constants";
import { HandleSerializer } from "./HandleSerializer";
import type { MessageSerializerMultiParams, MessageSerializerSingleParams } from "./types";

export class MessageSerializer {
    static async serialize({
        message,
        config = DEFAULT_MESSAGE_CONFIG,
        attachmentConfig = DEFAULT_ATTACHMENT_CONFIG,
        isForNotification = false
    }: MessageSerializerSingleParams): Promise<MessageResponse> {
        return (
            await MessageSerializer.serializeList({
                messages: [message],
                config: { ...DEFAULT_MESSAGE_CONFIG, ...config },
                attachmentConfig: { ...DEFAULT_ATTACHMENT_CONFIG, ...attachmentConfig },
                isForNotification
            })
        )[0];
    }

    static async serializeList({
        messages,
        config = DEFAULT_MESSAGE_CONFIG,
        attachmentConfig = DEFAULT_ATTACHMENT_CONFIG,
        isForNotification = false
    }: MessageSerializerMultiParams): Promise<MessageResponse[]> {
        // Convert the messages to their serialized versions
        const messageResponses: MessageResponse[] = [];
        for (const message of messages) {
            messageResponses.push(
                await MessageSerializer.convert({
                    message: message,
                    config: { ...DEFAULT_MESSAGE_CONFIG, ...config },
                    attachmentConfig: { ...DEFAULT_ATTACHMENT_CONFIG, ...attachmentConfig },
                    isForNotification
                })
            );
        }

        // Handle fetching the chat participants with the messages (if requested)
        const chatCache: { [key: string]: HandleResponse[] } = {};
        if (config.loadChatParticipants) {
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
                        const [chats, _] = await Server().iMessageRepo.getChats({
                            chatGuid: messages[i]?.chats[k].guid,
                            withParticipants: true
                        });
                        if (isNotEmpty(chats)) {
                            chatCache[messages[i]?.chats[k].guid] = await HandleSerializer.serializeList({
                                handles: chats[0].participants ?? [],
                                config: { includeChats: false, includeMessages: false }
                            });
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
        if (!config.parseAttributedBody || !config.parseMessageSummary || !config.parsePayloadData) {
            for (let i = 0; i < messageResponses.length; i++) {
                if (!config.parseAttributedBody && "attributedBody" in messageResponses[i]) {
                    messageResponses[i].attributedBody = null;
                }

                if (!config.parseMessageSummary && "messageSummaryInfo" in messageResponses[i]) {
                    messageResponses[i].messageSummaryInfo = null;
                }

                if (!config.parsePayloadData && "payloadData" in messageResponses[i]) {
                    messageResponses[i].payloadData = null;
                }
            }
        }

        if (config.enforceMaxSize) {
            const strData = JSON.stringify(messageResponses);
            const len = Buffer.byteLength(strData, "utf8");

            // If we've reached out max size, we need to clear the participants
            if (len > config.maxSizeBytes) {
                Server().log(
                    `MessageSerializer: Max size reached (${config.maxSizeBytes} bytes). Clearing participants.`,
                    "debug"
                );
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
        config = DEFAULT_MESSAGE_CONFIG,
        attachmentConfig = DEFAULT_ATTACHMENT_CONFIG,
        isForNotification = false
    }: MessageSerializerSingleParams): Promise<MessageResponse> {
        let output: MessageResponse = {
            originalROWID: message.ROWID,
            guid: message.guid,
            text: message.universalText(true),
            attributedBody: message.attributedBody,
            handle: message.handle
                ? await HandleSerializer.serialize({
                      handle: message.handle,
                      config: { includeChats: false, includeMessages: false }
                  })
                : null,
            handleId: message.handleId,
            otherHandle: message.otherHandle,
            attachments: await AttachmentSerializer.serializeList({
                attachments: message.attachments ?? [],
                config: attachmentConfig,
                isForNotification
            }),
            subject: message.subject,
            error: message.error,
            dateCreated: message.dateCreated ? message.dateCreated.getTime() : null,
            dateRead: message.dateRead ? message.dateRead.getTime() : null,
            dateDelivered: message.dateDelivered ? message.dateDelivered.getTime() : null,
            isDelivered: message.isDelivered,
            isFromMe: message.isFromMe,
            hasDdResults: message.hasDdResults,
            isArchived: message.isArchived,
            itemType: message.itemType,
            groupTitle: message.groupTitle,
            groupActionType: message.groupActionType,
            balloonBundleId: message.balloonBundleId,
            associatedMessageGuid: message.associatedMessageGuid,
            associatedMessageType: message.associatedMessageType,
            expressiveSendStyleId: message.expressiveSendStyleId,
            threadOriginatorGuid: message.threadOriginatorGuid,
            hasPayloadData: !!message.payloadData
        };

        // Non-essentials
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
                    timeExpressiveSendPlayed: message.timeExpressiveSendPlayed
                        ? message.timeExpressiveSendPlayed.getTime()
                        : null,
                    isAudioMessage: message.isAudioMessage,
                    replyToGuid: message.replyToGuid,
                    shareStatus: message.shareStatus,
                    shareDirection: message.shareDirection
                }
            };

            if (isMinMonterey) {
                output = {
                    ...output,
                    ...{
                        wasDeliveredQuietly: message.wasDeliveredQuietly ?? false,
                        didNotifyRecipient: message.didNotifyRecipient ?? false
                    }
                };
            }
        }

        if (config.includeChats) {
            output.chats = await ChatSerializer.serializeList({
                chats: message?.chats ?? [],
                config: { includeParticipants: false, includeMessages: false },
                isForNotification
            });
        }

        if (isMinHighSierra) {
            output.messageSummaryInfo = message.messageSummaryInfo;
            output.payloadData = message.payloadData;
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
