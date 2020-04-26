import { Entity, PrimaryColumn } from "typeorm";

@Entity()
export class Device {
    @PrimaryColumn("text", { name: "name" })
    name: string;

    @PrimaryColumn("text", { name: "identifier" })
    identifier: string;
}
