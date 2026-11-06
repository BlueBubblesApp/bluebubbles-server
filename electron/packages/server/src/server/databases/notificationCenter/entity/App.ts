import { Entity, Column, PrimaryColumn, OneToOne } from "typeorm";
import { Record } from "./Record";


@Entity("app")
export class App {
    @PrimaryColumn({ name: "app_id", type: "integer" })
    id: number;

    @Column({ name: "identifier", type: "varchar" })
    identifier: string;

    @Column({ name: "badge", type: "integer", nullable: true, default: null })
    badge: number;

    @OneToOne(() => Record, record => record.app)
    record: Record;
}
