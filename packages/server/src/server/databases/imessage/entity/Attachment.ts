import { Entity, PrimaryGeneratedColumn, Column, ManyToMany, JoinTable } from "typeorm";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { MessagesDateTransformer } from "@server/databases/transformers/MessagesDateTransformer";
import { Message } from "@server/databases/imessage/entity/Message";
import { isEmpty } from "@server/helpers/utils";
import { isMinSierra, isMinHighSierra } from "@server/env";
import { conditional } from "conditional-decorator";
import * as mime from "mime-types";
import { FileSystem } from "@server/fileSystem";
import { AttributedBodyTransformer } from "@server/databases/transformers/AttributedBodyTransformer";

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
        transformer: MessagesDateTransformer
    })
    createdDate: Date;

    @Column({
        type: "integer",
        name: "start_date",
        default: 0,
        transformer: MessagesDateTransformer
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

    @Column({
        type: "blob",
        name: "user_info",
        nullable: true,
        transformer: AttributedBodyTransformer
    })
    userInfo: NodeJS.Dict<any>[] | null;

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
            nullable: true,
            transformer: AttributedBodyTransformer
        })
    )
    attributionInfo: NodeJS.Dict<any>[] | null;

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

    private getMimeTypeFromUserInfo(): string | null {
        if (isEmpty(this.userInfo)) return null;
        return this.userInfo[0]['mime-type'] ?? null;
    }

    getDimensions(): { height: number, width: number } | null {
        if (isEmpty(this.attributionInfo)) return null;
        const height = this.attributionInfo[0]?.pgensh;
        const width = this.attributionInfo[0]?.pgensw;
        if (!height || !width) return null;
        return { height, width };
    }

    getMimeType(): string {
        const fPath = FileSystem.getRealPath(this.filePath);
        let mType = this.mimeType ?? this.getMimeTypeFromUserInfo() ?? mime.lookup(fPath);
        if (!mType || isEmpty(mType as any)) mType = "application/octet-stream";
        return mType;
    }
}
