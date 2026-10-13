import { Entity, Column, PrimaryColumn, OneToOne, JoinColumn } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { App } from "./App";
import { AttributedBodyTransformer } from "@server/databases/transformers/AttributedBodyTransformer";
import { NSAttributedString } from "node-typedstream";
import { CocoaDateTransformer } from "@server/databases/transformers/CocoaDateTransformer";


type RecordData = {
    styl: number;
    intl: boolean;
    app: string;
    uuid: Buffer;
    date: number;
    srce: Buffer;
    orig: number;
    req: {
        body: string;
        titl: string;
        cate?: string;
        thre?: string;
        smac?: number;
        durl?: string;
        subt?: string;
        iden?: string;
        [key: string]: any;
    }
};

@Entity("record")
export class Record {
    @PrimaryColumn({ name: "rec_id", type: "integer" })
    id: number;

    @Column({ name: "app_id", type: "integer" })
    appId: number;

    @OneToOne(() => App, app => app.record)
    @JoinColumn({ name: "app_id", referencedColumnName: "id" })
    app: App;

    @Column({
        name: "uuid",
        type: "blob",
        nullable: false,
    })
    uuid: Blob;

    @Column({
        name: "data",
        type: "blob",
        nullable: false,
        transformer: AttributedBodyTransformer
    })
    data: RecordData[] | null;

    @Column({
        name: "request_date",
        type: "real",
        nullable: true,
        transformer: CocoaDateTransformer
    })
    requestDate: Date;

    @Column({
        name: "request_last_date",
        type: "real",
        nullable: true,
        transformer: CocoaDateTransformer
    })
    lastRequestDate: Date;

    @Column({
        name: "delivered_date",
        type: "real",
        nullable: true,
        transformer: CocoaDateTransformer
    })
    deliveredDate: Date;

    @Column({
        name: "presented",
        type: "integer",
        transformer: BooleanTransformer,
        default: 1
    })
    presented: boolean;

    @Column({ name: "style", type: "integer", default: 1 })
    style: boolean;

    @Column({
        name: "snooze_fire_date",
        type: "real",
        nullable: true,
        transformer: CocoaDateTransformer
    })
    snoozeFireDate: Date;
}
