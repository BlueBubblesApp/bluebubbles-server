import { Entity, PrimaryGeneratedColumn, Column, ManyToOne, JoinTable, JoinColumn, ManyToMany } from "typeorm";
import { conditional } from "conditional-decorator";

import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { MessagesDateTransformer } from "@server/databases/transformers/MessagesDateTransformer";
import { MessageTypeTransformer } from "@server/databases/transformers/MessageTypeTransformer";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { Chat } from "@server/databases/imessage/entity/Chat";
import { Attachment } from "@server/databases/imessage/entity/Attachment";
import { isEmpty, isNotEmpty, sanitizeStr } from "@server/helpers/utils";
import { isMinBigSur, isMinCatalina, isMinHighSierra, isMinMonterey, isMinSierra, isMinVentura } from "@server/env";
import { NSAttributedString } from "node-typedstream";
import { AttributedBodyTransformer } from "@server/databases/transformers/AttributedBodyTransformer";
import { AttributedBodyUtils } from "@server/utils/AttributedBodyUtils";

@Entity("message")
export class Message {
    universalText(sanitize = false): string | null {
        let text = this.text;
        const attributedText = AttributedBodyUtils.extractText(this.attributedBody);
        if (isEmpty(text) && !isEmpty(attributedText)) {
            text = attributedText;
        }

        return sanitize ? sanitizeStr(text) : text;
    }

    contentString(maxText = 15): string {
        let text = this.universalText(true) ?? "";
        const textLen = text.length;
        const attachments = this.attachments ?? [];
        const attachmentsLen = attachments.length;
        let subject = this.subject ?? "";
        const subjectLen = subject.length;

        // Build the content
        const parts = [];

        // If we have text, add it, but with the max length taken into account
        if (textLen > 0) {
            if (textLen > maxText) {
                text = `${text.substring(0, maxText)}...`;
            }

            parts.push(`"${text}"`);
        } else {
            parts.push(`<No Text>`);
        }

        // If we have a subject, add it, but with the max length taken into account
        if (subjectLen > 0) {
            if (subjectLen > maxText) {
                subject = `${subject.substring(0, maxText)}...`;
            }

            parts.push(`Subject: "${subject}"`);
        }

        // If we have attachments, print those out
        if (attachmentsLen > 0) parts.push(`Attachments: ${attachmentsLen}`);

        // Lastly, add the date
        parts.push(`Date: ${this.dateCreated.toLocaleString()}`);

        return parts.join("; ");
    }

    get retractedParts(): number[] {
        return this.messageSummaryInfo?.[0]?.retractedParts ?? [];
    }

    get hasUnsentParts(): boolean {
        return this.dateEdited && isNotEmpty(this.retractedParts, false);
    }

    get isFullyUnsent(): boolean {
        // It's fully unsent if we have unsent parts, and all parts are unsent
        return this.hasUnsentParts && this.retractedParts.length > 0 && this.partCount === 0;
    }

    get isPartiallyUnsent(): boolean {
        // It's partially unsent if we have unsent parts, but there are still parts left
        return this.hasUnsentParts && this.retractedParts.length > 0 && this.partCount > 0;
    }

    get lastUpdateTime(): Date {
        return this.dateRetracted ?? this.dateEdited ?? this.dateRead ?? this.dateDelivered ?? this.dateCreated;
    }

    get messageStatus(): String {
        return this.dateRetracted
            ? "Unsent"
            : this.isFullyUnsent
            ? "Unsent"
            : this.isPartiallyUnsent
            ? "Partially Unsent"
            : this.dateEdited
            ? "Edited"
            : this.dateRead
            ? "Read"
            : this.dateDelivered
            ? "Delivered"
            : "Sent";
    }

    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @Column({ type: "text", nullable: false })
    guid: string;

    @Column({ type: "text", nullable: true })
    text: string;

    @Column({ type: "integer", nullable: true, default: 0 })
    replace: number;

    @Column({
        name: "service_center",
        type: "text",
        nullable: true
    })
    serviceCenter: string;

    @ManyToOne(type => Handle)
    @JoinColumn({ name: "handle_id", referencedColumnName: "ROWID" })
    handle: Handle;

    @ManyToMany(type => Chat)
    @JoinTable({
        name: "chat_message_join",
        joinColumns: [{ name: "message_id" }],
        inverseJoinColumns: [{ name: "chat_id" }]
    })
    chats: Chat[];

    @ManyToMany(type => Attachment)
    @JoinTable({
        name: "message_attachment_join",
        joinColumns: [{ name: "message_id" }],
        inverseJoinColumns: [{ name: "attachment_id" }]
    })
    attachments: Attachment[];

    @Column({ name: "handle_id", type: "integer", nullable: true, default: 0 })
    handleId: number;

    @Column({ type: "text", nullable: true })
    subject: string;

    @Column({ type: "text", nullable: true })
    country: string;

    @Column({
        type: "blob",
        nullable: true,
        transformer: AttributedBodyTransformer
    })
    attributedBody: NSAttributedString[] | null;

    @Column({ type: "integer", nullable: true, default: 0 })
    version: number;

    @Column({ type: "integer", nullable: true, default: 0 })
    type: number;

    @Column({ type: "text", nullable: true, default: "iMessage" })
    service: string;

    @Column({ type: "text", nullable: true })
    account: string;

    @Column({ name: "account_guid", type: "text", nullable: true })
    accountGuid: string;

    @Column({
        type: "integer",
        nullable: true,
        default: 0
    })
    error: number;

    @Column({
        name: "date",
        type: "date",
        nullable: true,
        transformer: MessagesDateTransformer
    })
    dateCreated: Date;

    @Column({
        name: "date_read",
        type: "date",
        nullable: true,
        transformer: MessagesDateTransformer
    })
    dateRead: Date;

    @Column({
        name: "date_delivered",
        type: "date",
        nullable: true,
        transformer: MessagesDateTransformer
    })
    dateDelivered: Date;

    @Column({
        name: "is_delivered",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isDelivered: boolean;

    @Column({
        name: "is_finished",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isFinished: boolean;

    @Column({
        name: "is_emote",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isEmote: boolean;

    @Column({
        name: "is_from_me",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isFromMe: boolean;

    @Column({
        name: "is_empty",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isEmpty: boolean;

    @Column({
        name: "is_delayed",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isDelayed: boolean;

    @Column({
        name: "is_auto_reply",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isAutoReply: boolean;

    @Column({
        name: "is_prepared",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isPrepared: boolean;

    @Column({
        name: "is_read",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isRead: boolean;

    @Column({
        name: "is_system_message",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isSystemMessage: boolean;

    @Column({
        name: "is_sent",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isSent: boolean;

    @Column({
        name: "has_dd_results",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    hasDdResults: boolean;

    @Column({
        name: "is_service_message",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isServiceMessage: boolean;

    @Column({
        name: "is_forward",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isForward: boolean;

    @Column({
        name: "was_downgraded",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    wasDowngraded: boolean;

    @Column({
        name: "is_archive",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isArchived: boolean;

    @Column({
        name: "cache_has_attachments",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    cacheHasAttachments: boolean;

    @Column({ name: "cache_roomnames", type: "text", nullable: true })
    cacheRoomnames: string;

    @Column({
        name: "was_data_detected",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    wasDataDetected: boolean;

    @Column({
        name: "was_deduplicated",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    wasDeduplicated: boolean;

    @Column({
        name: "is_audio_message",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isAudioMessage: boolean;

    @Column({
        name: "is_played",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isPlayed: boolean;

    @Column({
        name: "date_played",
        type: "integer",
        transformer: MessagesDateTransformer,
        default: 0
    })
    datePlayed: Date;

    @Column({ name: "item_type", type: "integer", default: 0 })
    itemType: number;

    @Column({
        name: "other_handle",
        type: "integer",
        nullable: true,
        default: 0
    })
    otherHandle: number;

    @Column({ name: "group_title", type: "text" })
    groupTitle: string;

    @Column({ name: "group_action_type", type: "integer", default: 0 })
    groupActionType: number;

    @Column({ name: "share_status", type: "integer", default: 0 })
    shareStatus: number;

    @Column({ name: "share_direction", type: "integer", default: 0 })
    shareDirection: number;

    @Column({
        name: "is_expirable",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isExpirable: boolean;

    @Column({
        name: "expire_state",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isExpired: boolean;

    @Column({
        name: "message_action_type",
        type: "integer",
        default: 0
    })
    messageActionType: number;

    @Column({
        name: "message_source",
        type: "integer",
        default: 0
    })
    messageSource: number;

    @conditional(
        isMinSierra,
        Column({
            name: "associated_message_guid",
            type: "text",
            nullable: true
        })
    )
    associatedMessageGuid: string;

    @conditional(
        isMinSierra,
        Column({
            name: "associated_message_type",
            type: "text",
            transformer: MessageTypeTransformer,
            nullable: true
        })
    )
    associatedMessageType: string;

    @conditional(isMinHighSierra, Column({ name: "balloon_bundle_id", type: "text", nullable: true }))
    balloonBundleId: string;

    @conditional(
        isMinHighSierra,
        Column({
            name: "payload_data",
            type: "blob",
            nullable: true,
            transformer: AttributedBodyTransformer
        })
    )
    payloadData: NodeJS.Dict<any>[] | null;

    @conditional(isMinHighSierra, Column({ name: "expressive_send_style_id", type: "text", nullable: true }))
    expressiveSendStyleId: string;

    @conditional(
        isMinHighSierra,
        Column({
            name: "associated_message_range_location",
            type: "integer",
            default: 0
        })
    )
    associatedMessageRangeLocation: number;

    @conditional(
        isMinHighSierra,
        Column({
            name: "associated_message_range_length",
            type: "integer",
            default: 0
        })
    )
    associatedMessageRangeLength: number;

    @conditional(
        isMinHighSierra,
        Column({
            name: "time_expressive_send_played",
            type: "integer",
            transformer: MessagesDateTransformer,
            default: 0
        })
    )
    timeExpressiveSendPlayed: Date;

    @conditional(
        isMinHighSierra,
        Column({
            name: "message_summary_info",
            type: "blob",
            nullable: true,
            transformer: AttributedBodyTransformer
        })
    )
    messageSummaryInfo: NodeJS.Dict<any>[] | null;

    @conditional(
        isMinCatalina,
        Column({
            name: "reply_to_guid",
            type: "text",
            nullable: true
        })
    )
    replyToGuid: string;

    @conditional(
        isMinCatalina,
        Column({
            name: "is_corrupt",
            type: "integer",
            transformer: BooleanTransformer,
            default: 0
        })
    )
    isCorrupt: boolean;

    @conditional(
        isMinCatalina,
        Column({
            name: "is_spam",
            type: "integer",
            transformer: BooleanTransformer,
            default: 0
        })
    )
    isSpam: boolean;

    @conditional(
        isMinBigSur,
        Column({
            name: "thread_originator_guid",
            type: "text",
            nullable: true
        })
    )
    threadOriginatorGuid: string;

    @conditional(
        isMinBigSur,
        Column({
            name: "thread_originator_part",
            type: "text",
            nullable: true
        })
    )
    threadOriginatorPart: string;

    @conditional(
        isMinVentura,
        Column({
            name: "date_retracted",
            type: "date",
            transformer: MessagesDateTransformer,
            default: 0
        })
    )
    dateRetracted: Date;

    @conditional(
        isMinVentura,
        Column({
            name: "date_edited",
            type: "date",
            transformer: MessagesDateTransformer,
            default: 0
        })
    )
    dateEdited: Date;

    @conditional(
        isMinVentura,
        Column({
            name: "part_count",
            type: "integer",
            default: null
        })
    )
    partCount: number;

    @conditional(
        isMinMonterey,
        Column({
            name: "was_delivered_quietly",
            type: "integer",
            transformer: BooleanTransformer,
            default: 0
        })
    )
    wasDeliveredQuietly: boolean;

    @conditional(
        isMinMonterey,
        Column({
            name: "did_notify_recipient",
            type: "integer",
            transformer: BooleanTransformer,
            default: 0
        })
    )
    didNotifyRecipient: boolean;

    get isDigitalTouch(): boolean {
        return this.balloonBundleId === "com.apple.DigitalTouchBalloonProvider";
    }

    get isHandwritten(): boolean {
        return this.balloonBundleId === "com.apple.Handwriting.HandwritingProvider";
    }
}
