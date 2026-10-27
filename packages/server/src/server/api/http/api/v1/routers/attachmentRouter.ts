import { Next } from "koa";
import { RouterContext } from "koa-router";
import { nativeImage } from "electron";
import fs from "fs";

import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { convertAudio, convertImage } from "@server/databases/imessage/helpers/utils";
import { isEmpty, isTruthyBool } from "@server/helpers/utils";
import { AttachmentInterface } from "@server/api/interfaces/attachmentInterface";
import { FileStream, Success } from "../responses/success";
import { BadRequest, NotFound, ServerError } from "../responses/errors";
import { AttachmentSerializer } from "@server/api/serializers/AttachmentSerializer";

// The largest width/height an image can be resized to
const maxResizeDimension = 4096;

export class AttachmentRouter {
    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getAttachmentCount();
        return new Success(ctx, { data: { total } }).send();
    }

    static async find(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) throw new NotFound({ error: "Attachment does not exist!" });
        return new Success(ctx, { data: await AttachmentSerializer.serialize({ attachment }) }).send();
    }

    static async download(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const { height, width, quality, original, force } = ctx.request.query;
        const useOriginal = isTruthyBool(original as string);
        const forceDownload = isTruthyBool((force as string) ?? "true");

        // Fetch the info for the attachment by GUID
        let attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) {
            throw new NotFound({ error: "Attachment does not exist!" });
        }

        // If the attachment is known but isn't on disk (e.g. it was purged/offloaded to iCloud),
        // ask the Private API to download it. This needs the attachment's database row, so it
        // only applies to attachments that exist (a missing row is a 404 above).
        let aPath = FileSystem.getRealPath(attachment.filePath);
        const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        if (!fs.existsSync(aPath) && forceDownload && papiEnabled) {
            try {
                attachment = await AttachmentInterface.forceDownload(attachment);
                aPath = FileSystem.getRealPath(attachment.filePath);
            } catch (ex) {
                Server().log(`Failed to force download attachment (GUID: ${guid}): ${String(ex)}`);
            }
        }

        let mimeType = attachment.getMimeType();
        if (!fs.existsSync(aPath)) throw new ServerError({ error: "Attachment does not exist in disk!" });

        const g = attachment.guid;
        const og = attachment.originalGuid ?? "N/A";
        Server().log(`Attachment download request (MIME: ${mimeType}; GUID: ${g}; Original GUID: ${og})`, "debug");

        // If we want to resize the image, do so here
        if (!useOriginal) {
            const converters = [convertImage, convertAudio];
            for (const conversion of converters) {
                // Try to convert the attachments using available converters
                const newPath = await conversion(attachment, { originalMimeType: mimeType });
                if (newPath) {
                    aPath = newPath;
                    mimeType = attachment.mimeType ?? mimeType;
                    break;
                }
            }

            // Handle resizing the image
            if (mimeType.startsWith("image/") && mimeType !== "image/gif" && (quality || width || height)) {
                const opts: Partial<Electron.ResizeOptions> = {};

                // Parse opts
                // Each size is a new cached file and an up-front allocation, so cap them.
                // Anything that isn't a positive integer is ignored rather than cached under its own name.
                const parseDimension = (value: unknown): number | null => {
                    const parsed = Number.parseInt(value as string, 10);
                    return Number.isInteger(parsed) && parsed > 0 ? Math.min(parsed, maxResizeDimension) : null;
                };
                const parsedWidth = width ? parseDimension(width) : null;
                const parsedHeight = height ? parseDimension(height) : null;

                let newName = attachment.transferName;
                if (quality) {
                    newName += `.${quality as string}`;

                    const qualities = ["good", "better", "best"];
                    if (!qualities.includes(quality as string)) {
                        throw new BadRequest({ error: `Invalid quality specified! Must be one of: ${qualities.join(', ')}` });
                    }

                    opts.quality = quality as "good" | "better" | "best";
                }
                if (parsedHeight) {
                    newName += `.${parsedHeight}`;
                    opts.height = parsedHeight;
                }
                if (parsedWidth) {
                    newName += `.${parsedWidth}`;
                    opts.width = parsedWidth;
                }

                // See if we already have a cached attachment
                if (FileSystem.cachedAttachmentExists(attachment, newName)) {
                    aPath = FileSystem.cachedAttachmentPath(attachment, newName);
                } else {
                    let image = nativeImage.createFromPath(aPath);
                    image = image.resize(opts);
                    FileSystem.saveCachedAttachment(attachment, newName, image.toPNG());
                    aPath = FileSystem.cachedAttachmentPath(attachment, newName);
                }

                // Force setting it to a PNG because all resized images are PNGs
                mimeType = "image/png";
            }
        }

        Server().log(`Sending attachment (${mimeType}) with path: ${aPath}`, "debug");
        return new FileStream(ctx, aPath, mimeType).send();
    }

    static async downloadLive(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment || isEmpty(attachment.filePath)) throw new NotFound({ error: "Attachment does not exist!" });

        const aPath = FileSystem.getRealPath(attachment.filePath);
        if (!fs.existsSync(aPath)) throw new NotFound({ error: "Attachment does not exist in disk!" });

        // Replace the extension with .mov (if there is one). Otherwise just append .mov
        const livePhotoPath = AttachmentInterface.getLivePhotoPath(attachment);
        if (!livePhotoPath) throw new NotFound({ error: "Live photo does not exist for this attachment!" });

        return new FileStream(ctx, livePhotoPath, "video/quicktime").send();
    }

    static async blurhash(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const { height, width, quality } = ctx.request.query;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) throw new NotFound({ error: "Attachment does not exist!" });

        const aPath = FileSystem.getRealPath(attachment.filePath);
        const mimeType = attachment.getMimeType();

        // Double-check the mime-type to make sure it's a valid attachment for that
        if (!mimeType || !mimeType.startsWith("image")) {
            throw new NotFound({ error: "Attachment is not an image!" });
        }

        // Validate and set defaults for invalid values
        let trueWidth = width ? Number.parseInt(width as string, 10) : null;
        let trueHeight = height ? Number.parseInt(height as string, 10) : null;
        if (!trueHeight || trueHeight <= 0) trueHeight = 320;
        if (!trueWidth || trueWidth <= 0) trueWidth = 480;
        trueHeight = Math.min(trueHeight, maxResizeDimension);
        trueWidth = Math.min(trueWidth, maxResizeDimension);

        let blurhash: string;

        try {
            blurhash = await AttachmentInterface.getBlurhash({
                filePath: aPath,
                height: trueHeight,
                width: trueWidth,
                quality
            });
        } catch (ex: any) {
            throw new ServerError({
                message: "Failed to get blurhash for attachment!",
                error: ex?.message ?? String(ex)
            });
        }

        return new Success(ctx, { data: blurhash }).send();
    }

    static async uploadAttachment(ctx: RouterContext, _: Next) {
        const { files } = ctx.request;
        const attachment = files?.attachment as unknown as File;

        // Create a filename using the hash & extension of the attachment
        const location = await AttachmentInterface.upload(attachment.path, attachment.name);

        // The path will essentially be "<attachment dir>/<uuid>/<hash>.ext".
        // We want to get the <uuid> and <hash> parts.
        const parts = location.split("/");
        const filename = parts.pop();
        const uuid = parts.pop();

        // Return the last folder
        return new Success(ctx, { data: { path: `${uuid}/${filename}` } }).send();
    }

    static async forceDownload(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) {
            throw new BadRequest({ message: `An attachment with the GUID, "${guid}" does not exist!` });
        }

        await Server().privateApi.attachment.downloadPurged(guid);

        // Wait a max of 10 minutes
        await AttachmentInterface.forceDownload(attachment);
        return await AttachmentRouter.download(ctx, _);
    }
}
