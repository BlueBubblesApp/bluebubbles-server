import { Entity, PrimaryColumn } from "typeorm";

@Entity()
export class Device {
    @PrimaryColumn("text", { name: "identifier" })
    identifier: string;
}
