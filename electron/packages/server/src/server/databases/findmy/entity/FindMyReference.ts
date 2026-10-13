import { Entity, Column, PrimaryColumn } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";


@Entity("cfurl_cache_receiver_data")
export class FindMyReference {
    @PrimaryColumn({ name: "entry_ID", type: "integer" })
    id: number;

    @Column({ name: "isDataOnFS", type: "integer", nullable: true, transformer: BooleanTransformer })
    isDataOnFS: boolean;

    @Column({ name: "receiver_data", type: "blob", nullable: true })
    requestObject: Blob;
}
