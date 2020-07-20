import { Entity, PrimaryGeneratedColumn, Column } from "typeorm";

@Entity({ name: "queue" })
export class Queue {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "temp_guid", nullable: false })
    tempGuid: string;

    @Column("text", { name: "text", nullable: false })
    text: string;

    @Column("text", { name: "chat_guid", nullable: false })
    chatGuid: string;

    @Column("integer", { name: "date_created", nullable: false })
    dateCreated: number;
}
