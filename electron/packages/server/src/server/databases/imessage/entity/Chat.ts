import { Entity, PrimaryGeneratedColumn, Column, ManyToMany, JoinTable } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { Message } from "@server/databases/imessage/entity/Message";
import { AttributedBodyTransformer } from "@server/databases/transformers/AttributedBodyTransformer";
import { isMinHighSierra } from "@server/env";
import { MessagesDateTransformer } from "@server/databases/transformers/MessagesDateTransformer";
import { conditional } from "conditional-decorator";

@Entity("chat")
export class Chat {
    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @ManyToMany(type => Handle)
    @JoinTable({
        name: "chat_handle_join",
        joinColumns: [{ name: "chat_id" }],
        inverseJoinColumns: [{ name: "handle_id" }]
    })
    participants: Handle[];

    @ManyToMany(type => Message)
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

    @Column({
        type: "blob",
        nullable: true,
        transformer: AttributedBodyTransformer
    })
    properties: NodeJS.Dict<any>[] | null;

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

    @conditional(
        isMinHighSierra,
        Column({
            name: "last_read_message_timestamp",
            type: "date",
            transformer: MessagesDateTransformer,
            default: 0
        })
    )
    lastReadMessageTimestamp: Date;

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

    get isGroup() {
        return this.style === 43;
    }
}
