import { nativeImage, NativeImage } from "electron";
import * as fs from "fs";
import * as path from "path";
import * as base64 from "byte-base64";
import { Entity, PrimaryGeneratedColumn, Column, ManyToMany, JoinTable } from "typeorm";

import { Server } from "@server/index";
import { BooleanTransformer } from "@server/databases/transformers/BooleanTransformer";
import { DateTransformer } from "@server/databases/transformers/DateTransformer";
import { Message } from "@server/databases/imessage/entity/Message";
import { convertAudio, getAttachmentMetadata, getBlurHash } from "@server/databases/imessage/helpers/utils";
import { AttachmentResponse } from "@server/types";
import { FileSystem } from "@server/fileSystem";
import { Metadata } from "@server/fileSystem/types";

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

    @Column({
        type: "integer",
        name: "is_sticker",
        default: 0,
        transformer: BooleanTransformer
    })
    isSticker: boolean;

    @Column({ type: "blob", name: "sticker_user_info", nullable: true })
    stickerUserInfo: Blob;

    @Column({ type: "blob", name: "attribution_info", nullable: true })
    attributionInfo: Blob;

    @Column({
        type: "integer",
        name: "hide_attachment",
        default: 0,
        transformer: BooleanTransformer
    })
    hideAttachment: boolean;
}

const handledImageMimes = ["image/jpeg", "image/jpg", "image/png", "image/bmp", "image/tiff", "image/gif"];
export const getAttachmentResponse = async (
    attachment: Attachment,
    withData = false,
    withBlurhash = true
): Promise<AttachmentResponse> => {
    let data: Uint8Array | string = null;
    let metadata: Metadata = null;
    let blurhash: string = null;
    let image: NativeImage = null;

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

            // If the attachment exists, do some things
            const exists = fs.existsSync(fPath);
            if (exists) {
                // If we want data, get the data
                if (withData) {
                    data = Uint8Array.from(fs.readFileSync(fPath));
                }

                // If the user wants the blurhash, get it for them!
                if (withBlurhash && handledImageMimes.includes(tableData.mimeType)) {
                    image = nativeImage.createFromPath(fPath);
                    blurhash = await getBlurHash(image);
                }

                // Fetch the attachment metadata if there is a mimeType
                metadata = await getAttachmentMetadata(tableData);

                // If there is no data, return null for the data
                // Otherwise, convert it to a base64 string
                if (data) {
                    data = base64.bytesToBase64(data as Uint8Array);
                }
            }
        } catch (ex) {
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
        blurhash,
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
