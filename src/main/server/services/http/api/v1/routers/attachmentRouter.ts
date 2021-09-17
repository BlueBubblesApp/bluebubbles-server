import { Next } from "koa";
import { RouterContext } from "koa-router";
import * as mime from "mime";
import * as fs from "fs";

import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";

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
        // const { height, width, quality } = ctx.request.query;

        // Fetch the info for the attachment by GUID
        const attachment = await Server().iMessageRepo.getAttachment(guid);
        if (!attachment) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Attachment does not exist!");
            return;
        }

        const aPath = FileSystem.getRealPath(attachment.filePath);
        let mimeType = attachment.mimeType ?? mime.lookup(aPath);
        if (!mimeType) {
            mimeType = "application/octet-stream";
        }

        // // If we want to resize the image, do so here
        // if (mimeType.startsWith("image/") && mimeType !== "image/gif" && (quality || width || height)) {
        //     const opts: Partial<Electron.ResizeOptions> = {};
        //     console.log("PARSING");

        //     // Parse opts
        //     const parsedWidth = parseNumber(width as string);
        //     const parsedHeight = parseNumber(height as string);
        //     const parsedQuality = parseQuality(quality as string);

        //     let newName = attachment.transferName;
        //     if (parsedQuality) {
        //         newName += `.${parsedQuality}`;
        //         opts.quality = parsedQuality;
        //     }
        //     if (parsedHeight) {
        //         newName += `.${parsedHeight}`;
        //         opts.height = parsedHeight;
        //     }
        //     if (parsedWidth) {
        //         newName += `.${parsedWidth}`;
        //         opts.width = parsedWidth;
        //     }

        //     // See if we already have a cached attachment
        //     if (FileSystem.cachedAttachmentExists(attachment, newName)) {
        //         console.log("EXISTS");
        //         aPath = FileSystem.cachedAttachmentPath(attachment, newName);
        //     } else {
        //         console.log("DOESNt");
        //         const image = nativeImage.createFromPath(aPath);
        //         // image.resize(opts);
        //         FileSystem.saveCachedAttachment(attachment, newName, image.toBitmap());
        //         aPath = FileSystem.cachedAttachmentPath(attachment, newName);
        //     }
        // }

        const src = fs.createReadStream(aPath);
        ctx.response.set("Content-Type", mimeType as string);
        ctx.body = src;
    }
}
