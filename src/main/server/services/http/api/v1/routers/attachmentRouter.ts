import { Next } from "koa";
import { RouterContext } from "koa-router";
import { nativeImage } from "electron";
import * as mime from "mime-types";
import * as fs from "fs";

import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { parseNumber, parseQuality } from "@server/services/http/helpers";
import { createBadRequestResponse, createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { AttachmentInterface } from "../interfaces/attachmentInterface";

export class AttachmentRouter {
    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getAttachmentCount();
        ctx.body = createSuccessResponse({ total });
    }

    static async find(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Attachment does not exist!");
            return;
        }

        ctx.body = createSuccessResponse(await getAttachmentResponse(attachment));
    }

    static async download(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const { height, width, quality } = ctx.request.query;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Attachment does not exist!");
            return;
        }

        let aPath = FileSystem.getRealPath(attachment.filePath);
        let mimeType = attachment.mimeType ?? mime.lookup(aPath);
        if (!mimeType) {
            mimeType = "application/octet-stream";
        }

        // If we want to resize the image, do so here
        if (mimeType.startsWith("image/") && mimeType !== "image/gif" && (quality || width || height)) {
            const opts: Partial<Electron.ResizeOptions> = {};

            // Parse opts
            const parsedWidth = parseNumber(width as string);
            const parsedHeight = parseNumber(height as string);
            const parsedQuality = parseQuality(quality as string);

            let newName = attachment.transferName;
            if (parsedQuality) {
                newName += `.${parsedQuality}`;
                opts.quality = parsedQuality;
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

        const src = fs.createReadStream(aPath);
        ctx.response.set("Content-Type", mimeType as string);
        ctx.body = src;
    }

    static async blurhash(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const { height, width, quality } = ctx.request.query;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Attachment does not exist!");
            return;
        }

        const aPath = FileSystem.getRealPath(attachment.filePath);
        const mimeType = attachment.mimeType ?? mime.lookup(aPath);

        // Double-check the mime-type to make sure it's a valid attachment for that
        if (!mimeType || !mimeType.startsWith("image")) {
            if (!attachment) {
                ctx.status = 400;
                ctx.body = createBadRequestResponse("This attachment is not an image!");
                return;
            }
        }

        // Validate the quality
        if (quality && !["good", "better", "best"].includes(quality as string)) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Invalid quality! Must be one of: good, better, best");
            return;
        }

        // Validate and set defaults for invalid values
        let trueHeight = parseNumber(height as string);
        let trueWidth = parseNumber(width as string);
        if (trueHeight && trueHeight <= 0) trueHeight = 320;
        if (trueWidth && trueWidth <= 0) trueWidth = 480;

        const blurhash = await AttachmentInterface.getBlurhash({
            filePath: aPath,
            height: trueHeight,
            width: trueWidth,
            quality
        });

        ctx.body = createSuccessResponse(blurhash);
    }
}
