import { Base64Transformer } from "@server/databases/transformers/Base64Transformer";
import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn, UpdateDateColumn, OneToMany, Unique } from "typeorm";
import { ContactAddress } from "./ContactAddress";

@Entity({ name: "contact" })
@Unique(["firstName", "lastName", "displayName"])
export class Contact {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "first_name", nullable: false, default: "" })
    firstName: string;

    @Column("text", { name: "last_name", nullable: false, default: "" })
    lastName: string;

    @Column("text", { name: "display_name", nullable: false, default: "" })
    displayName: string;

    @OneToMany(() => ContactAddress, contactAddress => contactAddress.contact)
    addresses: ContactAddress[];

    @Column("text", { name: "avatar", transformer: Base64Transformer, nullable: true })
    avatar: Buffer;

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;
}
