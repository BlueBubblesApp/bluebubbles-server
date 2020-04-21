import {
    Entity,
    PrimaryGeneratedColumn,
    Column,
    DatabaseType,
    ManyToMany,
    JoinTable,
    OneToMany,
    JoinColumn
} from "typeorm";
import { BooleanTransformer } from "@server/api/imessage/transformers/BooleanTransformer";
import { DateTransformer } from "@server/api/imessage/transformers/DateTransformer";
import { Handle } from "@server/api/imessage/entity/Handle";
import { Message } from "@server/api/imessage/entity/Message";

@Entity("chat")
export class Chat {
    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @ManyToMany((type) => Handle)
    @JoinTable({
        name: "chat_handle_join",
        joinColumns: [{ name: "chat_id" }],
        inverseJoinColumns: [{ name: "handle_id" }]
    })
    participants: Handle[];

    @ManyToMany((type) => Message)
    @JoinTable({
        name: "chat_message_join",
        joinColumns: [{ name: "chat_id" }],
        inverseJoinColumns: [{ name: "message_id" }]
    })
    messages: Message[];

    @Column({ type: "text", nullable: false })
    guid: string;

    @Column({ type: "integer", nullable: true })
    style: number;

    @Column({ type: "integer", nullable: true })
    state: number;

    @Column({ name: "account_id", type: "text", nullable: true })
    accountId: number;

    @Column({ type: "blob", nullable: true })
    properties: Blob;

    @Column({ name: "chat_identifier", type: "text", nullable: true })
    chatIdentifier: string;

    @Column({ name: "service_name", type: "text", nullable: true })
    serviceName: string;

    @Column({ name: "room_name", type: "text", nullable: true })
    roomName: string;

    @Column({ name: "account_login", type: "text", nullable: true })
    accountLogin: string;

    @Column({
        name: "is_archived",
        type: "integer",
        nullable: true,
        transformer: BooleanTransformer
    })
    isArchived: boolean;

    @Column({ name: "last_addressed_handle", type: "text", nullable: true })
    lastAddressedHandle: string;

    @Column({ name: "display_name", type: "text", nullable: true })
    displayName: string;

    @Column({ name: "group_id", type: "text", nullable: true })
    groupId: string;

    @Column({
        name: "is_filtered",
        type: "integer",
        nullable: true,
        transformer: BooleanTransformer
    })
    isFiltered: boolean;

    @Column({
        name: "successful_query",
        type: "integer",
        nullable: true,
        transformer: BooleanTransformer
    })
    successfulQuery: boolean;

    @Column({ name: "engram_id", type: "text", nullable: true })
    engramId: string;

    @Column({ name: "server_change_token", type: "text", nullable: true })
    serverChangeToken: string;

    @Column({
        name: "ck_sync_state",
        type: "integer",
        nullable: true,
        transformer: BooleanTransformer
    })
    ckSyncState: boolean;

    @Column({ name: "original_group_id", type: "text", nullable: true })
    originalGroupId: string;

    @Column({
        name: "last_read_message_timestamp",
        type: "integer",
        nullable: true,
        transformer: DateTransformer
    })
    lastReadMessageTimestamp: number;

    @Column({ name: "sr_server_change_token", type: "text", nullable: true })
    srServerChangeToken: string;

    @Column({ name: "sr_ck_sync_state", type: "integer", nullable: true })
    srCkSyncState: number;

    @Column({ name: "cloudkit_record_id", type: "text", nullable: true })
    cloudkitRecordId: string;

    @Column({ name: "sr_cloudkit_record_id", type: "text", nullable: true })
    srCloudkitRecordId: string;

    @Column({ name: "last_addressed_sim_id", type: "text", nullable: true })
    lastAddressedSimId: string;

    @Column({
        name: "is_blackholed",
        type: "integer",
        nullable: true,
        transformer: BooleanTransformer
    })
    isBlackholed: boolean;
}
