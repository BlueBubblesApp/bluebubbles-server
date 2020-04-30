import {
    Entity,
    PrimaryGeneratedColumn,
    Column,
    OneToMany,
    JoinColumn,
    JoinTable,
    ManyToMany
} from "typeorm";

import { Message, getMessageResponse } from "@server/api/imessage/entity/Message";
import { Chat, getChatResponse } from "@server/api/imessage/entity/Chat";
import { HandleResponse } from "@server/types";

@Entity("handle")
export class Handle {
    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @OneToMany((type) => Message, (message) => message.from)
    @JoinColumn({ name: "ROWID", referencedColumnName: "handle_id" })
    messages: Message[];

    @ManyToMany((type) => Chat)
    @JoinTable({
        name: "chat_handle_join",
        joinColumns: [{ name: "handle_id" }],
        inverseJoinColumns: [{ name: "chat_id" }]
    })
    chats: Chat[];

    @Column({ type: "text", nullable: false })
    id: string;

    @Column({ type: "text", nullable: true })
    country: string;

    @Column({ type: "text", nullable: false, default: "iMessage" })
    service: string;

    @Column({ name: "uncanonicalized_id", type: "text", nullable: true })
    uncanonicalizedId: string;
}

export const getHandleResponse = (tableData: Handle): HandleResponse => {
    return {
        messages: tableData.messages
            ? tableData.messages.map((item) => getMessageResponse(item))
            : [],
        chats: tableData.chats
            ? tableData.chats.map((item) => getChatResponse(item))
            : [],
        address: tableData.id,
        country: tableData.country,
        uncanonicalizedId: tableData.uncanonicalizedId
    };
}