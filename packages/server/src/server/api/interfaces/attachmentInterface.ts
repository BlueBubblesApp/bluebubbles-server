import { nativeImage } from "electron";
import fs from "fs";
import { getBlurHash, isEmpty, isNotEmpty, resultAwaiter } from "@server/helpers/utils";
import { FileSystem } from "@server/fileSystem";
import { Attachment } from "@server/databases/imessage/entity/Attachment";
import { Server } from "@server";

export class AttachmentInterface {
    static livePhotoExts = ["png", "jpeg", "jpg", "heic", "tiff"];

    static async getBlurhash({
        filePath,
        width = null,
        height = null,
        componentX = 3,
        componentY = 3,
        quality = "good"
    }: any): Promise<string> {
        const bh = await getBlurHash({
            image: nativeImage.createFromPath(filePath),
            width,
            height,
            quality,
            componentX,
            componentY
        });
        return bh;
    }

    static async upload(path: string, name: string): Promise<string> {
        if (!path || !name) throw new Error("No path/name provided!");
        if (!fs.existsSync(path)) throw new Error("File does not exist!");

        // Copy the attachment to a more permanent storage using the papi method.
        // This is so the attachment gets copied to the iMessage directory.
        return FileSystem.copyAttachment(path, name, "private-api");
    }

    static getLivePhotoPath(attachment: Attachment): string | null {
        // If we don't have a path, return null
        const fPath = attachment?.filePath;
        if (isEmpty(fPath)) return null;

        // Get the existing extension (if any).
        // If it's been converted, it'll have a double-extension.
        let ext = fPath.includes('.heic.jpeg') ? 'heic.jpeg' : fPath.split(".").pop() ?? "";

        // If the extension is not an image extension, return null
        if (!AttachmentInterface.livePhotoExts.includes(ext.toLowerCase())) return null;

        // Escape periods in the extension for the regex
        ext = ext.replace(/\./g, "\\.");
    
        // Get the path to the live photo
        // Replace the extension with .mov, or add it if there is no extension
        const livePath = isNotEmpty(ext) ? fPath.replace(new RegExp(`\\.${ext}$`), ".mov") : `${fPath}.mov`;
        const realPath = FileSystem.getRealPath(livePath);

        // If the live photo doesn't exist, return null
        if (!fs.existsSync(realPath)) return null;

        // If the .mov file exists, return the path
        return realPath;
    }

    static async forceDownload(attachment: Attachment): Promise<Attachment> {
        await Server().privateApi.attachment.downloadPurged(attachment.guid);

        attachment = await resultAwaiter({
            maxWaitMs: 1000 * 60 * 10,
            initialWaitMs: 1000 * 5,
            waitMultiplier: 1,
            getData: (_: any) => {
                return Server().iMessageRepo.getAttachment(attachment.guid);
            },
            dataLoopCondition: (data: Attachment) => {
                return !data || data.transferState !== 5;
            }
        });

        if (!attachment || attachment.transferState !== 5) {
            throw new Error(`Failed to download attachment! Transfer State: ${attachment?.transferState}`);
        }

        return attachment;
    }
}
