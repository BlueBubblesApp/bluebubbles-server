import { nativeImage } from "electron";
import fs from "fs";
import { getBlurHash, isEmpty } from "@server/helpers/utils";
import { FileSystem } from "@server/fileSystem";
import { Attachment } from "@server/databases/imessage/entity/Attachment";

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
        FileSystem.copyAttachment(path, name, "private-api");

        // Return the name of the attachment
        return name;
    }

    static getLivePhotoPath(attachment: Attachment): string | null {
        // If we don't have a path, return null
        const fPath = attachment?.filePath;
        if (isEmpty(fPath)) return null;

        // Get the extension
        const ext = fPath.split(".").pop();

        // If the extension is not an image extension, return null
        if (!AttachmentInterface.livePhotoExts.includes(ext)) return null;

        // Get the path to the live photo by replacing the extension with .mov
        const livePath = ext !== fPath ? fPath.replace(`.${ext}`, ".mov") : `${fPath}.mov`;
        const realPath = FileSystem.getRealPath(livePath);
        
        // If the live photo doesn't exist, return null
        if (!fs.existsSync(realPath)) return null;

        // If the .mov file exists, return the path
        return realPath;
    }
}
