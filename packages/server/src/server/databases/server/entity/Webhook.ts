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

    // Optional secret used to sign outbound webhook requests (HMAC-SHA256)
    @Column("text", { name: "signing_secret", nullable: true })
    signing_secret: string;

    @CreateDateColumn()
    created: Date;
}
