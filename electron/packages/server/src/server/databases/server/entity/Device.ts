import { Entity, PrimaryColumn, Column } from "typeorm";

@Entity({ name: "device" })
export class Device {
    @PrimaryColumn("text", { name: "name" })
    name: string;

    @PrimaryColumn("text", { name: "identifier" })
    identifier: string;

    @Column("int", { name: "last_active", nullable: true })
    last_active: number;
}
