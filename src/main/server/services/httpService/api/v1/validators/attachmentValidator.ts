import { RouterContext } from "koa-router";
import { Next } from "koa";

import { ValidateInput } from "./index";

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
        quality: "string|in:good,better,best"
    };

    static async validateDownload(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.query, AttachmentValidator.downloadRules);
        await next();
    }
}
