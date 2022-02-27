import { Next } from "koa";
import { RouterContext } from "koa-router";
import { ValidateInput } from "./index";

export class HandleValidator {
    static findRules = {
        guid: "required|string"
    };

    static async validateFind(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.params, HandleValidator.findRules);
        await next();
    }

    static queryBodyRules = {
        address: "string",
        with: "array|in:chat,chats,chat.participants,chats.participants",
        offset: "numeric|min:0",
        limit: "numeric|min:1|max:1000"
    };

    static async validateQuery(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, HandleValidator.queryBodyRules);
        await next();
    }
}
