/* eslint-disable max-classes-per-file */
import {
    Entity,
    PrimaryGeneratedColumn,
    Column,
    OneToMany,
    JoinColumn,
    JoinTable,
    ManyToMany
} from "typeorm";
import { MessageNew, Message } from "@server/api/imessage/entity/Message";
import { Chat, ChatNew } from "@server/api/imessage/entity/Chat";

@Entity("handle")
export class Handle {
    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @OneToMany((type) => Message, (message) => message.from)
    @JoinColumn({ name: "ROWID", referencedColumnName: "handle_id" })
    messages: typeof Message[];

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

export class HandleNew extends Handle {
    @OneToMany((type) => MessageNew, (message) => message.from)
    @JoinColumn({ name: "ROWID", referencedColumnName: "handle_id" })
    messages: typeof MessageNew[];

    @ManyToMany((type) => ChatNew)
    @JoinTable({
        name: "chat_handle_join",
        joinColumns: [{ name: "handle_id" }],
        inverseJoinColumns: [{ name: "chat_id" }]
    })
    chats: ChatNew[];

    @Column({ name: "person_centric_id", type: "text", nullable: true })
    personCentricId: string;
}
