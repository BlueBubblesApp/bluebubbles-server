import { getDateUsing2001 } from "../../helpers/dateUtil";
import { convertAttributedBody } from "../../helpers/utils";
import { Attachment } from "../Attachment";
import { Chat } from "../Chat";
import { Handle } from "../Handle";
import { Message } from "../Message";

export class MessageDecoder {
    messageCache: Map<number, Message> = new Map();

    handleCache: Map<number, Handle> = new Map();

    chatCache: Map<number, Chat> = new Map();

    attachmentCache: Map<number, Attachment> = new Map();

    decode(entry: Record<string, any>): Message {
        let message = this.messageCache.get(entry.message_ROWID);
        if (!message) {
            message = new Message();
            message.ROWID = entry.message_ROWID;
            message.guid = entry.message_guid;
            message.text = entry.message_text;
            message.replace = entry.message_replace;
            message.serviceCenter = entry.message_service_center;
            message.handleId = entry.message_handle_id;
            message.subject = entry.message_subject;
            message.country = entry.message_country;
            message.attributedBody = convertAttributedBody(entry.message_attributedBody);
            message.version = entry.message_version;
            message.type = entry.message_type;
            message.service = entry.message_service;
            message.account = entry.message_account;
            message.accountGuid = entry.message_account_guid;
            message.error = entry.message_error;
            message.dateCreated = getDateUsing2001(entry.message_date);
            message.dateRead = getDateUsing2001(entry.message_date_read);
            message.dateDelivered = getDateUsing2001(entry.message_date_delivered);
            message.isDelivered = Boolean(entry.message_is_delivered);
            message.isFinished = Boolean(entry.message_is_finished);
            message.isEmote = Boolean(entry.message_is_emote);
            message.isFromMe = Boolean(entry.message_is_from_me);
            message.isEmpty = Boolean(entry.message_is_empty);
            message.isDelayed = Boolean(entry.message_is_delayed);
            message.isAutoReply = Boolean(entry.message_is_auto_reply);
            message.isPrepared = Boolean(entry.message_is_prepared);
            message.isRead = Boolean(entry.message_is_read);
            message.isSystemMessage = Boolean(entry.message_is_system_message);
            message.isSent = Boolean(entry.message_is_sent);
            message.hasDdResults = Boolean(entry.message_has_dd_results);
            message.isServiceMessage = Boolean(entry.message_is_service_message);
            message.isForward = Boolean(entry.message_is_forward);
            message.wasDowngraded = Boolean(entry.message_was_downgraded);
            message.isArchived = Boolean(entry.message_is_archive);
            message.cacheHasAttachments = Boolean(entry.message_cache_has_attachments);
            message.cacheRoomnames = entry.message_cache_roomnames;
            message.wasDataDetected = Boolean(entry.message_was_data_detected);
            message.wasDeduplicated = Boolean(entry.message_was_deduplicated);
            message.isAudioMessage = Boolean(entry.message_is_audio_message);
            message.isPlayed = Boolean(entry.message_is_played);
            message.datePlayed = getDateUsing2001(entry.message_date_played);
            message.itemType = entry.message_item_type;
            message.otherHandle = entry.message_other_handle;
            message.groupTitle = entry.message_group_title;
            message.groupActionType = entry.message_group_action_type;
            message.shareStatus = entry.message_share_status;
            message.shareDirection = entry.message_share_direction;
            message.isExpirable = Boolean(entry.message_is_expirable);
            message.isExpired = Boolean(entry.message_expire_state);
            message.messageActionType = entry.message_message_action_type;
            message.messageSource = entry.message_message_source;
            message.associatedMessageGuid = entry.message_associated_message_guid;
            message.associatedMessageType = entry.message_associated_message_type;
            message.balloonBundleId = entry.message_balloon_bundle_id;
            message.payloadData = convertAttributedBody(entry.message_payload_data);
            message.expressiveSendStyleId = entry.message_expressive_send_style_id;
            message.associatedMessageRangeLocation = entry.message_associated_message_range_location;
            message.associatedMessageRangeLength = entry.message_associated_message_range_length;
            message.timeExpressiveSendPlayed = getDateUsing2001(entry.message_time_expressive_send_played);
            message.expressiveSendStyleId = entry.message_expressive_send_style_id;
            message.messageSummaryInfo = convertAttributedBody(entry.message_message_summary_info);
            message.replyToGuid = entry.message_reply_to_guid;
            message.isCorrupt = Boolean(entry.message_is_corrupt);
            message.isSpam = Boolean(entry.message_is_spam);
            message.threadOriginatorGuid = entry.message_thread_originator_guid;
            message.threadOriginatorPart = entry.message_thread_originator_part;
            message.dateRetracted = getDateUsing2001(entry.message_date_retracted);
            message.dateEdited = getDateUsing2001(entry.message_date_edited);
            message.partCount = entry.message_part_count;
            message.wasDeliveredQuietly = Boolean(entry.message_was_delivered_quietly);
            message.didNotifyRecipient = Boolean(entry.message_did_notify_recipient);
        
            message.chats = [];
            message.attachments = [];
        }

        const attachment = this.decodeAttachment(entry);
        if (attachment) {
            const attachmentExists = message.attachments.find((a) => a.ROWID === attachment.ROWID);
            if (!attachmentExists) message.attachments.push(attachment);
        }

        const chat = this.decodeChat(entry);
        if (chat) {
            const chatExists = message.chats.find((c) => c.ROWID === chat.ROWID);
            if (!chatExists) message.chats.push(chat);
        }

        if (!message.handle) {
            const handle = this.decodeHandle(entry);
            message.handle = handle;
        }

        this.messageCache.set(message.ROWID, message);
        return message;
    }

    decodeList(messages: Record<string, any>[]): Message[] {
        return messages.map((entry) => this.decode(entry));
    }

    decodeHandle(entry: Record<string, any>): Handle | null {
        if (!entry?.handle_ROWID) return null;
        let handle = this.handleCache.get(entry.handle_ROWID);
        if (handle) return handle;

        handle = new Handle();
        handle.ROWID = entry.handle_ROWID;
        handle.id = entry.handle_id;
        handle.country = entry.handle_country;
        handle.service = entry.handle_service;
        handle.uncanonicalizedId = entry.handle_uncanonicalized_id;

        this.handleCache.set(handle.ROWID, handle);
        return handle;
    }

    decodeChat(entry: Record<string, any>): Chat | null {
        if (!entry?.chat_ROWID) return null;
        let chat = this.chatCache.get(entry.chat_ROWID);
        if (chat) return chat;

        chat = new Chat();
        chat.ROWID = entry.chat_ROWID;
        chat.guid = entry.chat_guid;
        chat.style = entry.chat_style;
        chat.state = entry.chat_state;
        chat.accountId = entry.chat_account_id;
        chat.properties = convertAttributedBody(entry.chat_properties);
        chat.chatIdentifier = entry.chat_chat_identifier;
        chat.serviceName = entry.chat_service_name;
        chat.roomName = entry.chat_room_name;
        chat.accountLogin = entry.chat_account_login;
        chat.isArchived = Boolean(entry.chat_is_archived);
        chat.lastReadMessageTimestamp = getDateUsing2001(entry.chat_last_read_message_timestamp);
        chat.lastAddressedHandle = entry.chat_last_addressed_handle;
        chat.displayName = entry.chat_display_name;
        chat.groupId = entry.chat_group_id;
        chat.isFiltered = Boolean(entry.chat_is_filtered);
        chat.successfulQuery = Boolean(entry.chat_successful_query);

        this.chatCache.set(chat.ROWID, chat);
        return chat;
    }

    decodeAttachment(entry: Record<string, any>): Attachment | null {
        if (!entry?.attachment_ROWID) return null;
        let attachment = this.attachmentCache.get(entry.attachment_ROWID);
        if (attachment) return attachment;

        attachment = new Attachment();
        attachment.ROWID = entry.attachment_ROWID;
        attachment.guid = entry.attachment_guid;
        attachment.createdDate = entry.attachment_created_date;
        attachment.startDate = entry.attachment_start_date;
        attachment.filePath = entry.attachment_filename;
        attachment.uti = entry.attachment_uti;
        attachment.mimeType = entry.attachment_mime_type;
        attachment.transferState = entry.attachment_transfer_state;
        attachment.isOutgoing = entry.attachment_is_outgoing;
        attachment.userInfo = entry.attachment_user_info;
        attachment.transferName = entry.attachment_transfer_name;
        attachment.totalBytes = entry.attachment_total_bytes;
        attachment.isSticker = entry.attachment_is_sticker;
        attachment.stickerUserInfo = entry.attachment_sticker_user_info;
        attachment.attributionInfo = entry.attachment_attribution_info;
        attachment.hideAttachment = entry.attachment_hide_attachment;
        attachment.originalGuid = entry.attachment_original_guid;

        this.attachmentCache.set(attachment.ROWID, attachment);
        return attachment;
    }
}