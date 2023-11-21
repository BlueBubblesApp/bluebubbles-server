import { Entity, Column, PrimaryColumn } from "typeorm";

@Entity({ name: "token" })
export class Token {
    @PrimaryColumn("text", { name: "name" })
    name: string;

    @Column("text", { name: "password", unique: false })
    password: string;
}