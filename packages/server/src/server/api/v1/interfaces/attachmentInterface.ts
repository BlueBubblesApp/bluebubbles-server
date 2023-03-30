import { nativeImage } from "electron";
import { getBlurHash } from "@server/helpers/utils";
import { FileSystem } from "@server/fileSystem";
import fs from "fs";

export class AttachmentInterface {
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
}
