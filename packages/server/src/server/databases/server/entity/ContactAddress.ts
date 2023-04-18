import {
    Entity,
    PrimaryGeneratedColumn,
    Column,
    CreateDateColumn,
    UpdateDateColumn,
    ManyToOne,
    Unique
} from "typeorm";
import { Contact } from "./Contact";

@Entity({ name: "contact_address" })
@Unique(["address", "contact"])
export class ContactAddress {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "address", nullable: false })
    address: string;

    @Column("text", { name: "type", nullable: false })
    type: string;

    @ManyToOne(() => Contact, contact => contact.addresses, { onDelete: "CASCADE" })
    contact: Contact;

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;
}
