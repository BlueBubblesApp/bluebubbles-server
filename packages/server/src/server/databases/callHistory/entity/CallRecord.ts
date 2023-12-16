import { Entity, Column, PrimaryColumn } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import type { CallCategory, CallDisconnectedCause } from "./types";
import { AttributedBodyTransformer } from "@server/databases/transformers/AttributedBodyTransformer";
import { CocoaDateTransformer } from "@server/databases/transformers/CocoaDateTransformer";
import { BlobStringTransformer } from "@server/databases/transformers/BlobStringTransformer";

// ZCALLTYPE
// 8 - FaceTime Video
// 16 - FaceTime Audio


// Z CALL CATEGORY
// 1 - Audio
// 2 - Video

// Z ANSWERED -> 1/0 -> True/False

@Entity("ZCALLRECORD")
export class CallRecord {
    @PrimaryColumn({ name: "Z_PK", type: "integer" })
    id: number;

    @Column({
        name: "ZANSWERED",
        type: "integer",
        transformer: BooleanTransformer
    })
    answered: boolean;

    @Column({
        name: "ZCALL_CATEGORY",
        type: "integer"
    })
    category: CallCategory;

    @Column({
        name: "ZDISCONNECTED_CAUSE",
        type: "integer"
    })
    disconnectedCause: CallDisconnectedCause;

    @Column({
        name: "ZADDRESS",
        type: "blob",
        transformer: BlobStringTransformer
    })
    address: string;

    @Column({
        name: "ZDATE",
        type: "date",
        nullable: true,
        transformer: CocoaDateTransformer
    })
    date: Date;
}
