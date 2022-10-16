import { Entity, PrimaryGeneratedColumn, Column, OneToMany, JoinColumn, JoinTable, ManyToMany } from "typeorm";
import { Message } from "@server/databases/imessage/entity/Message";
import { Chat } from "@server/databases/imessage/entity/Chat";

@Entity("handle")
export class Handle {
    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @OneToMany(type => Message, message => message.handle)
    @JoinColumn({ name: "ROWID", referencedColumnName: "handle_id" })
    messages: Message[];

    @ManyToMany(type => Chat)
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
