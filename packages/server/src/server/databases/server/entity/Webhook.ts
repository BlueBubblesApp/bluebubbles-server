import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn } from "typeorm";

@Entity({ name: "webhook" })
export class Webhook {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "url", nullable: false, unique: true })
    url: string;

    // JSON String
    @Column("text", { name: "events", nullable: false })
    events: string;

    // JSON String — optional list of chat GUIDs to filter events by
    @Column("text", { name: "chat_guids", nullable: true })
    chatGuids: string;

    @CreateDateColumn()
    created: Date;
}
