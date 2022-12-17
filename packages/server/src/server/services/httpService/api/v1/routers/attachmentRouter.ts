import { Next } from "koa";
import { RouterContext } from "koa-router";
import { nativeImage } from "electron";

import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { convertAudio, convertImage } from "@server/databases/imessage/helpers/utils";
import { isTruthyBool } from "@server/helpers/utils";
import { AttachmentInterface } from "@server/api/v1/interfaces/attachmentInterface";
import { FileStream, Success } from "../responses/success";
import { NotFound, ServerError } from "../responses/errors";
import { AttachmentSerializer } from "@server/api/v1/serializers/AttachmentSerializer";

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
        const { height, width, quality, original } = ctx.request.query;
        const useOriginal = isTruthyBool(original as string);

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) throw new NotFound({ error: "Attachment does not exist!" });

        let aPath = FileSystem.getRealPath(attachment.filePath);
        let mimeType = attachment.getMimeType();

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
                const parsedWidth = width ? Number.parseInt(width as string, 10) : null;
                const parsedHeight = height ? Number.parseInt(height as string, 10) : null;

                let newName = attachment.transferName;
                if (quality) {
                    newName += `.${quality as string}`;
                    opts.quality = quality as string;
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

        let blurhash: string;

        try {
            blurhash = await AttachmentInterface.getBlurhash({
                filePath: aPath,
                height: trueHeight,
                width: trueWidth,
                quality
            });
        } catch (ex: any) {
            return new ServerError({
                message: "Failed to get blurhash for attachment!",
                error: ex?.message ?? String(ex)
            });
        }

        return new Success(ctx, { data: blurhash }).send();
    }
}
