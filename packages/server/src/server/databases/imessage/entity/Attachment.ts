import * as fs from "fs";
import * as base64 from "byte-base64";
import { Entity, PrimaryGeneratedColumn, Column, ManyToMany, JoinTable } from "typeorm";

import { Server } from "@server";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { DateTransformer } from "@server/databases/transformers/DateTransformer";
import { Message } from "@server/databases/imessage/entity/Message";
import { convertAudio, convertImage, getAttachmentMetadata } from "@server/databases/imessage/helpers/utils";
import { AttachmentResponse } from "@server/types";
import { FileSystem } from "@server/fileSystem";
import { Metadata } from "@server/fileSystem/types";
import { isNotEmpty, isMinSierra, isEmpty } from "@server/helpers/utils";
import { conditional } from "conditional-decorator";
import * as mime from "mime-types";

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
        transformer: DateTransformer
    })
    createdDate: Date;

    @Column({
        type: "integer",
        name: "start_date",
        default: 0,
        transformer: DateTransformer
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

    getMimeType(): string {
        let mType = this.mimeType ?? mime.lookup(this.filePath);
        if (!mType || isEmpty(mType as Object)) mType = 'application/octet-stream';
        return mType;
    }
}

export const getAttachmentResponse = async (attachment: Attachment, withData = false): Promise<AttachmentResponse> => {
    let data: Uint8Array | string = null;
    let metadata: Metadata = null;

    // Get the fully qualified path
    const tableData = attachment;
    let fPath = tableData.filePath;

    // If the attachment isn't finished downloading, the path will be null
    if (fPath) {
        fPath = FileSystem.getRealPath(fPath);

        try {
            // If the attachment is a caf, let's convert it
            if (tableData.uti === "com.apple.coreaudio-format") {
                const newPath = await convertAudio(tableData);
                fPath = newPath ?? fPath;
            }

            if (isNotEmpty(tableData?.mimeType)) {
                // If the attachment is a HEIC, convert it to a JPEG
                if (tableData.mimeType.startsWith("image/heic")) {
                    const newPath = await convertImage(tableData);
                    fPath = newPath ?? fPath;
                }
            }

            // If the attachment exists, do some things
            const exists = fs.existsSync(fPath);
            if (exists) {
                // If we want data, get the data
                if (withData) {
                    data = Uint8Array.from(fs.readFileSync(fPath));
                }

                // Fetch the attachment metadata if there is a mimeType
                metadata = await getAttachmentMetadata(tableData);

                // If there is no data, return null for the data
                // Otherwise, convert it to a base64 string
                if (data) {
                    data = base64.bytesToBase64(data as Uint8Array);
                }
            }
        } catch (ex: any) {
            console.log(ex);
            Server().log(`Could not read file [${fPath}]: ${ex.message}`, "error");
        }
    } else {
        console.warn("Attachment hasn't been downloaded yet!");
    }

    return {
        originalROWID: tableData.ROWID,
        guid: tableData.guid,
        messages: tableData.messages ? tableData.messages.map(item => item.guid) : [],
        data: data as string,
        height: (metadata?.height ?? 0) as number,
        width: (metadata?.width ?? 0) as number,
        uti: tableData.uti,
        mimeType: tableData.mimeType,
        transferState: tableData.transferState,
        isOutgoing: tableData.isOutgoing,
        transferName: tableData.transferName,
        totalBytes: tableData.totalBytes,
        isSticker: tableData.isSticker,
        hideAttachment: tableData.hideAttachment,
        metadata
    };
};
