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

    @Column("boolean", { name: "block_private_addresses", nullable: false, default: false })
    blockPrivateAddresses: boolean;

    @Column("boolean", { name: "require_https", nullable: false, default: false })
    requireHttps: boolean;

    @Column("boolean", { name: "follow_redirects", nullable: false, default: false })
    followRedirects: boolean;

    @CreateDateColumn()
    created: Date;
}
