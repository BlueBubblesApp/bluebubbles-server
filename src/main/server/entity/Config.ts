import { Entity, PrimaryGeneratedColumn, Column } from "typeorm";

@Entity()
export class Config {
    @PrimaryGeneratedColumn()
    name: string;

    @Column("text", { nullable: true })
    value: string;
}
