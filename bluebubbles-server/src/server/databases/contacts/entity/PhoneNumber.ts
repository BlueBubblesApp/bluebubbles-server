import { Entity, PrimaryGeneratedColumn, Column, JoinColumn, ManyToOne } from "typeorm";

import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { Record } from "@server/databases/contacts/entity/Record";

@Entity("ZABCDPHONENUMBER")
export class PhoneNumber {
    @PrimaryGeneratedColumn({ name: "Z_PK" })
    id: number;

    @Column({
        name: "ZISPRIMARY",
        type: "integer",
        transformer: BooleanTransformer,
        nullable: false,
        default: 0
    })
    isPrimary: boolean;

    @ManyToOne(type => Record)
    @JoinColumn({ name: "ZOWNER", referencedColumnName: "id" })
    record: Record;

    @Column({ name: "ZOWNER", type: "varchar", nullable: false })
    ownerId: string;

    @Column({ name: "ZFULLNUMBER", type: "varchar", nullable: true })
    address: string;

    @Column({ name: "ZLABEL", type: "varchar", nullable: true })
    label: string;

    @Column({ name: "ZLASTFOURDIGITS", type: "varchar", nullable: true })
    lastFourDigits: string;

    @Column({ name: "ZAREACODE", type: "varchar", nullable: true })
    areaCode: string;

    @Column({ name: "ZCOUNTRYCODE", type: "varchar", nullable: true })
    countryCode: string;

    @Column({ name: "ZEXTENSION", type: "varchar", nullable: true })
    extension: string;
}
