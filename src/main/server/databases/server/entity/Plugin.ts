import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn, UpdateDateColumn, Unique } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { JsonTransformer } from "@server/databases/transformers/JsonTransformer";

@Entity({ name: "plugin" })
@Unique(["name", "type"])
export class Plugin {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    @Column("text", { name: "name", nullable: false })
    name: string;

    @Column({
        name: "enabled",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    enabled: boolean;

    @Column("text", { name: "displayName", nullable: false })
    displayName: string;

    @Column("text", { name: "type", nullable: false })
    type: string;

    @Column("text", { name: "description", nullable: false, default: "" })
    description: string;

    @Column("integer", { name: "version", nullable: false, default: 1 })
    version: number;

    @Column({
        name: "properties",
        type: "text",
        transformer: JsonTransformer,
        default: null
    })
    properties: object;

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;
}
