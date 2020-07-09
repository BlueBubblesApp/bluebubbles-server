import { Entity, PrimaryGeneratedColumn, Column, JoinColumn, OneToMany } from "typeorm";
import { PhoneNumber } from "@server/api/contacts/entity/PhoneNumber";
import { Email } from "@server/api/contacts/entity/Email";

@Entity("ZABCDRECORD")
export class Record {
    @PrimaryGeneratedColumn({ name: "Z_PK" })
    id: number;

    @OneToMany(type => PhoneNumber, address => address.record)
    @JoinColumn({ name: "Z_PK", referencedColumnName: "id" })
    phoneNumbers: PhoneNumber[];

    @OneToMany(type => Email, address => address.record)
    @JoinColumn({ name: "Z_PK", referencedColumnName: "id" })
    emails: Email[];

    @Column({ name: "ZFIRSTNAME", type: "varchar", nullable: true })
    firstName: string;

    @Column({ name: "ZLASTNAME", type: "varchar", nullable: true })
    lastName: string;

    @Column({ name: "ZORGANIZATION", type: "varchar", nullable: true })
    organization: string;
}
