import { Next } from "koa";
import { RouterContext } from "koa-router";
import { nativeImage } from "electron";
import * as mime from "mime-types";

import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { AttachmentInterface } from "@server/api/v1/interfaces/attachmentInterface";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { FileStream, Success } from "../responses/success";
import { NotFound } from "../responses/errors";

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
        return new Success(ctx, { data: await getAttachmentResponse(attachment) }).send();
    }

    static async download(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const { height, width, quality } = ctx.request.query;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) throw new NotFound({ error: "Attachment does not exist!" });

        let aPath = FileSystem.getRealPath(attachment.filePath);
        let mimeType = attachment.mimeType ?? mime.lookup(aPath);
        if (!mimeType) {
            mimeType = "application/octet-stream";
        }

        // If we want to resize the image, do so here
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

        return new FileStream(ctx, aPath, mimeType).send();
    }

    static async blurhash(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const { height, width, quality } = ctx.request.query;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) throw new NotFound({ error: "Attachment does not exist!" });

        const aPath = FileSystem.getRealPath(attachment.filePath);
        const mimeType = attachment.mimeType ?? mime.lookup(aPath);

        // Double-check the mime-type to make sure it's a valid attachment for that
        if (!mimeType || !mimeType.startsWith("image")) {
            throw new NotFound({ error: "Attachment is not an image!" });
        }

        // Validate and set defaults for invalid values
        let trueWidth = width ? Number.parseInt(width as string, 10) : null;
        let trueHeight = height ? Number.parseInt(height as string, 10) : null;
        if (!trueHeight || trueHeight <= 0) trueHeight = 320;
        if (!trueWidth || trueWidth <= 0) trueWidth = 480;

        const blurhash = await AttachmentInterface.getBlurhash({
            filePath: aPath,
            height: trueHeight,
            width: trueWidth,
            quality
        });

        return new Success(ctx, { data: blurhash }).send();
    }
}
