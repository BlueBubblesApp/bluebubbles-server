import { Entity, PrimaryGeneratedColumn, Column, PrimaryColumn } from "typeorm";

@Entity()
export class Config {
    @PrimaryColumn("text", { name: "name" })
    name: string;

    @Column("text", { name: "value", nullable: true })
    value: string;
}
