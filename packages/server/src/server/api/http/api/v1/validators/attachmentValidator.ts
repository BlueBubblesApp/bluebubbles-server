import { RouterContext } from "koa-router";
import { Next } from "koa";

import { ValidateInput } from "./index";
import { BadRequest } from "../responses/errors";

export class AttachmentValidator {
    static findParamRules = {
        guid: "required|string"
    };

    static async validateFind(ctx: RouterContext, next: Next) {
        ValidateInput(ctx.params, AttachmentValidator.findParamRules);
        await next();
    }

    static downloadRules = {
        height: "numeric|min:1",
        width: "numeric|min:1",
        quality: "string|in:good,better,best",
        force: "boolean",
        original: "boolean"
    };

    static async validateDownload(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.query, AttachmentValidator.downloadRules);
        await next();
    }

    static async validateUpload(ctx: RouterContext, next: Next) {
        const { files } = ctx.request;

        // Make sure the message isn't already in the queue
        const attachment = files?.attachment as unknown as File;
        if (!attachment || attachment.size === 0) {
            throw new BadRequest({ error: "Attachment not provided or was empty!" });
        }

        await next();
    }
}
