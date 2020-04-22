/* eslint-disable max-classes-per-file */
import {
    Entity,
    PrimaryGeneratedColumn,
    Column,
    ManyToOne,
    JoinTable,
    JoinColumn,
    ManyToMany
} from "typeorm";
import { BooleanTransformer } from "@server/api/imessage/transformers/BooleanTransformer";
import { DateTransformer } from "@server/api/imessage/transformers/DateTransformer";
import { MessageTypeTransformer } from "@server/api/imessage/transformers/MessageTypeTransformer";
import { Handle } from "@server/api/imessage/entity/Handle";
import { Chat } from "@server/api/imessage/entity/Chat";

@Entity("message")
export class Message {
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

    @ManyToOne((type) => Handle)
    @JoinColumn({ name: "handle_id", referencedColumnName: "ROWID" })
    from: Handle;

    @ManyToMany((type) => Chat)
    @JoinTable({
        name: "chat_message_join",
        joinColumns: [{ name: "message_id" }],
        inverseJoinColumns: [{ name: "chat_id" }]
    })
    chats: Chat[];

    @Column({ name: "handle_id", type: "integer", nullable: true, default: 0 })
    handleId: number;

    @Column({ type: "text", nullable: true })
    subject: string;

    @Column({ type: "text", nullable: true })
    country: string;

    @Column({ type: "blob", nullable: true })
    attributedBody: Blob;

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
        transformer: BooleanTransformer,
        default: 0
    })
    error: boolean;

    @Column({
        name: "date",
        type: "date",
        nullable: true,
        transformer: DateTransformer
    })
    dateCreated: number;

    @Column({
        name: "date_read",
        type: "date",
        nullable: true,
        transformer: DateTransformer
    })
    dateRead: number;

    @Column({
        name: "date_delivered",
        type: "date",
        nullable: true,
        transformer: DateTransformer
    })
    dateDelivered: number;

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
        transformer: DateTransformer,
        default: 0
    })
    datePlayed: number;

    @Column({ name: "item_type", type: "integer", default: 0 })
    itemType: number;

    @Column({ name: "other_handle", type: "integer", default: 0 })
    otherHandle: number;

    @Column({ name: "group_title", type: "text" })
    groupTitle: string;

    @Column({ name: "group_action_type", type: "integer", default: 0 })
    groupActionType: number;

    @Column({
        name: "share_status",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    shareStatus: boolean;

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

    @Column({
        name: "associated_message_guid",
        type: "text",
        nullable: true
    })
    associatedMessageGuid: string;

    @Column({
        name: "associated_message_type",
        type: "integer",
        transformer: MessageTypeTransformer,
        default: 0
    })
    associatedMessageType: number;

    @Column({ name: "balloon_bundle_id", type: "text", nullable: true })
    balloonBundleId: string;

    @Column({ name: "payload_data", type: "blob", nullable: true })
    payloadData: Blob;

    @Column({ name: "expressive_send_style_id", type: "text", nullable: true })
    expressive_send_style_id: string;

    @Column({
        name: "associated_message_range_location",
        type: "integer",
        default: 0
    })
    associatedMessageRangeLocation: number;

    @Column({
        name: "associated_message_range_length",
        type: "integer",
        default: 0
    })
    associatedMessageRangeLength: number;

    @Column({
        name: "time_expressive_send_played",
        type: "integer",
        transformer: DateTransformer,
        default: 0
    })
    timeExpressiveSendStyleId: number;

    @Column({ name: "message_summary_info", type: "blob", nullable: true })
    messageSummaryInfo: Blob;
}
