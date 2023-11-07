import { Next } from "koa";
import { RouterContext } from "koa-router";
import { ValidateInput } from "./index";

export class AlertsValidator {
    static readRules = {
        ids: "required|array"
    };

    static async validateRead(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, AlertsValidator.readRules);
        await next();
    }
}
