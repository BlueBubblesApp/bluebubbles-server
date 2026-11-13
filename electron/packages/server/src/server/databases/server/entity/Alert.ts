import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn, UpdateDateColumn } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";

@Entity({ name: "alert" })
export class Alert {
    @PrimaryGeneratedColumn({ name: "id" })
    id: number;

    /**
     * Possible Types:
     *     info
     *     warn
     *     error
     *     success
     */
    @Column("text", { name: "type", nullable: false, default: "info" })
    type: string;

    @Column("text", { name: "message", nullable: false })
    value: string;

    @Column({
        name: "is_read",
        type: "integer",
        transformer: BooleanTransformer,
        default: 0
    })
    isRead: boolean;

    @CreateDateColumn()
    created: Date;

    @UpdateDateColumn()
    updated: Date;
}
