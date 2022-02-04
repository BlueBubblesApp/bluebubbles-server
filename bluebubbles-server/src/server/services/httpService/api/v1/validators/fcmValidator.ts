import { Next } from "koa";
import { RouterContext } from "koa-router";
import { ValidateInput } from "./index";

export class FcmValidator {
    static registerRules = {
        name: "required|string",
        identifier: "required|string"
    };

    static async validateRegistration(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, FcmValidator.registerRules);
        await next();
    }
}
