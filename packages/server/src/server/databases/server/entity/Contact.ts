import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn, UpdateDateColumn, OneToMany, JoinTable } from "typeorm";
import { ContactAddress } from "./ContactAddress";

@Entity({ name: "contact" })
export class Contact {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "first_name", nullable: false, unique: true })
    firstName: string;

    @Column("text", { name: "last_name", nullable: false, unique: true })
    lastName: string;

    @OneToMany(() => ContactAddress, contactAddress => contactAddress.contact)
    addresses: ContactAddress[];

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;
}
