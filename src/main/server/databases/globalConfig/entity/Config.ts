import { Entity, Column, PrimaryColumn } from "typeorm";

@Entity({ name: "config" })
export class Config {
    @PrimaryColumn("text", { name: "name" })
    name: string;

    @Column("text", { name: "value", nullable: true })
    value: string;

    @Column("varchar", { name: "type", nullable: false, default: "string" })
    type: string;
}
