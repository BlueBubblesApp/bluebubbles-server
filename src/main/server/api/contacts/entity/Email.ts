import { Entity, PrimaryGeneratedColumn, Column, JoinColumn, ManyToOne } from "typeorm";

import { BooleanTransformer } from "@server/api/transformers/BooleanTransformer";
import { Record } from "@server/api/contacts/entity/Record";

@Entity("ZABCDEMAILADDRESS")
export class Email {
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

    @Column({ name: "ZADDRESSNORMALIZED", type: "varchar", nullable: true })
    address: string;

    @Column({ name: "ZLABEL", type: "varchar", nullable: true })
    label: string;
}
