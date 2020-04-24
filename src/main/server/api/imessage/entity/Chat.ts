import {
    Entity,
    PrimaryGeneratedColumn,
    Column,
    ManyToMany,
    JoinTable
} from "typeorm";
import { BooleanTransformer } from "@server/api/imessage/transformers/BooleanTransformer";
import { Handle, getHandleResponse } from "@server/api/imessage/entity/Handle";
import { Message, getMessageResponse } from "@server/api/imessage/entity/Message";
import { ChatResponse } from "@server/helpers/dataTypes";

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
}

export const getChatResponse = (tableData: Chat): ChatResponse => {
    return {
        guid: tableData.guid,
        participants: tableData.participants
            ? tableData.participants.map((item) => getHandleResponse(item))
            : [],
        messages: tableData.messages
            ? tableData.messages.map((item) => getMessageResponse(item))
            : [],
        style: tableData.style,
        chatIdentifier: tableData.chatIdentifier,
        isArchived: tableData.isArchived,
        displayName: tableData.displayName,
        groupId: tableData.groupId
    };
};
