import { Entity, PrimaryGeneratedColumn, Column, ManyToMany, JoinTable } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { AppleDateTransformer } from "@server/databases/transformers/AppleDateTransformer";
import { Message } from "@server/databases/imessage/entity/Message";
import { isMinSierra, isMinHighSierra, isEmpty } from "@server/helpers/utils";
import { conditional } from "conditional-decorator";
import * as mime from "mime-types";
import { FileSystem } from "@server/fileSystem";

@Entity("attachment")
export class Attachment {
    @PrimaryGeneratedColumn({ name: "ROWID" })
    ROWID: number;

    @ManyToMany(type => Message)
    @JoinTable({
        name: "message_attachment_join",
        joinColumns: [{ name: "attachment_id" }],
        inverseJoinColumns: [{ name: "message_id" }]
    })
    messages: Message[];

    @Column({ type: "text", nullable: false })
    guid: string;

    @Column({
        type: "integer",
        name: "created_date",
        default: 0,
        transformer: AppleDateTransformer
    })
    createdDate: Date;

    @Column({
        type: "integer",
        name: "start_date",
        default: 0,
        transformer: AppleDateTransformer
    })
    startDate: Date;

    @Column({ type: "text", name: "filename", nullable: false })
    filePath: string;

    @Column({ type: "text", nullable: false })
    uti: string;

    @Column({ type: "text", name: "mime_type", nullable: true })
    mimeType: string;

    @Column({ type: "integer", name: "transfer_state", default: 0 })
    transferState: number;

    @Column({
        type: "integer",
        name: "is_outgoing",
        default: 0,
        transformer: BooleanTransformer
    })
    isOutgoing: boolean;

    @Column({ type: "blob", name: "user_info", nullable: true })
    userInfo: Blob;

    @Column({ type: "text", name: "transfer_name", nullable: false })
    transferName: string;

    @Column({ type: "integer", name: "total_bytes", default: 0 })
    totalBytes: number;

    @conditional(
        isMinSierra,
        Column({
            type: "integer",
            name: "is_sticker",
            default: 0,
            transformer: BooleanTransformer
        })
    )
    isSticker: boolean;

    @conditional(
        isMinSierra,
        Column({
            type: "blob",
            name: "sticker_user_info",
            nullable: true
        })
    )
    stickerUserInfo: Blob;

    @conditional(
        isMinSierra,
        Column({
            type: "blob",
            name: "attribution_info",
            nullable: true
        })
    )
    attributionInfo: Blob;

    @conditional(
        isMinSierra,
        Column({
            type: "integer",
            name: "hide_attachment",
            default: 0,
            transformer: BooleanTransformer
        })
    )
    hideAttachment: boolean;

    @conditional(
        isMinHighSierra,
        Column({
            type: "text",
            unique: true,
            name: "original_guid"
        })
    )
    originalGuid: string;

    getMimeType(): string {
        const fPath = FileSystem.getRealPath(this.filePath);
        let mType = this.mimeType ?? mime.lookup(fPath);
        if (!mType || isEmpty(mType as any)) mType = "application/octet-stream";
        return mType;
    }
}
