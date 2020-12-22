import * as fs from "fs";

import { NativeImage } from "electron";
import { basename } from "path";
import { encode as blurHashEncode } from "blurhash";

import { Server } from "@server/index";
import { Message } from "@server/databases/imessage/entity/Message";
import { FileSystem } from "@server/fileSystem";
import { Metadata } from "@server/fileSystem/types";
import { Attachment } from "../entity/Attachment";

export const getBlurHash = async (image: NativeImage) => {
    let blurhash: string = null;
    let calcImage = image;

    try {
        let size = calcImage.getSize();

        // If the image is "too big", rescale it so blurhash is computed faster
        if (size.width > 320) {
            calcImage = calcImage.resize({ width: 320, quality: "good" });
            size = calcImage.getSize();
        }

        // Compute blurhash
        blurhash = blurHashEncode(Uint8ClampedArray.from(calcImage.toBitmap()), size.width, size.height, 3, 3);
    } catch (ex) {
        console.log(ex);
        Server().log(`Could not compute blurhash: ${ex.message}`, "error");
    }

    return blurhash;
};

export const getCacheName = (message: Message) => {
    const delivered = message.dateDelivered ? message.dateDelivered.getTime() : 0;
    const read = message.dateRead ? message.dateRead.getTime() : 0;
    return `${message.guid}:${delivered}:${read}`;
};

export const convertAudio = async (attachment: Attachment): Promise<string> => {
    const newPath = `${FileSystem.convertDir}/${attachment.guid}.mp3`;
    const theAttachment = attachment;

    // If the path doesn't exist, let's convert the attachment
    let failed = false;
    if (!fs.existsSync(newPath)) {
        try {
            Server().log(`Converting attachment, ${theAttachment.transferName}, to an MP3...`);
            await FileSystem.convertCafToMp3(theAttachment, newPath);
        } catch (ex) {
            failed = true;
            Server().log(`Failed to convert CAF to MP3 for attachment, ${theAttachment.transferName}`);
            Server().log(ex, "error");
        }
    }

    if (!failed) {
        // If conversion is successful, we need to modify the attachment a bit
        theAttachment.mimeType = "audio/mp3";
        theAttachment.filePath = newPath;
        theAttachment.transferName = basename(newPath).replace(".caf", ".mp3");

        // Set the fPath to the newly converted path
        return newPath;
    }

    return null;
};

export const getAttachmentMetadata = async (attachment: Attachment): Promise<Metadata> => {
    let metadata: Metadata;
    if (attachment.uti !== "com.apple.coreaudio-format" && !attachment.mimeType) return metadata;

    if (attachment.uti === "com.apple.coreaudio-format" || attachment.mimeType.startsWith("audio")) {
        metadata = await FileSystem.getAudioMetadata(attachment.filePath);
    } else if (attachment.mimeType.startsWith("image")) {
        metadata = await FileSystem.getImageMetadata(attachment.filePath);
    } else if (attachment.mimeType.startsWith("video")) {
        metadata = await FileSystem.getVideoMetadata(attachment.filePath);
    }

    return metadata;
};
