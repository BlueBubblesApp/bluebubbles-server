import { Entity, Column, PrimaryColumn, CreateDateColumn } from "typeorm";

@Entity({ name: "token" })
export class Token {
    @PrimaryColumn("text", { name: "name" })
    name: string;

    @Column("text", { name: "password", unique: false })
    password: string;

    @CreateDateColumn()
    createdAt: Date;

    @Column("text", { name: "expireAt" })
    expireAt: number;
}