import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn, UpdateDateColumn, ManyToOne, JoinTable } from "typeorm";
import { Contact } from "./Contact";

@Entity({ name: "contact_address" })
export class ContactAddress {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "address", nullable: false, unique: true })
    address: string;

    @Column("text", { name: "type", nullable: false })
    type: string;

    @ManyToOne(() => Contact, contact => contact.addresses)
    contact: Contact;

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;
}
