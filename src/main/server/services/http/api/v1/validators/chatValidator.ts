import { RouterContext } from "koa-router";
import { Next } from "koa";

import { ValidateInput } from "./index";

export class ChatValidator {
    static getMessagesRules = {
        with: "string",
        sort: "string|in:DESC,ASC",
        after: "numeric|min:0",
        before: "numeric|min:1",
        offset: "numeric|min:0",
        limit: "numeric|min:1|max:1000"
    };

    static async validateGetMessages(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.query, ChatValidator.getMessagesRules);
        await next();
    }

    static queryRules = {
        with: "array|in:participants,lastMessage,archived",
        sort: "string|in:lastmessage",
        offset: "numeric|min:0",
        limit: "numeric|min:1|max:1000"
    };

    static async validateQuery(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, ChatValidator.queryRules);
        await next();
    }

    static updateRules = {
        displayName: "string|min:1"
    };

    static async validateUpdate(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, ChatValidator.updateRules);
        await next();
    }

    static createRules = {
        addresses: "required|array",
        message: "string"
    };

    static async validateCreate(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, ChatValidator.createRules);
        await next();
    }

    static toggleParticipantRules = {
        address: "required|string",
        message: "string"
    };

    static async validateToggleParticipant(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, ChatValidator.createRules);
        await next();
    }
}
