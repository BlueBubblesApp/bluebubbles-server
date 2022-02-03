import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn } from "typeorm";

@Entity({ name: "webhook" })
export class Webhook {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "url", nullable: false, unique: true })
    url: string;

    @CreateDateColumn()
    created: Date;
}
