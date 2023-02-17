import { Next } from "koa";
import { RouterContext } from "koa-router";
import { ValidateInput, ValidateJSON } from "./index";

export class ThemeValidator {
    static rules = {
        name: "required|string|min:3|max:50",
        data: "required"
    };

    static deleteRules = {
        name: "required|string|min:3|max:50"
    };

    static async validate(ctx: RouterContext, next: Next) {
        const { data } = ValidateInput(ctx.request.body, ThemeValidator.rules);
        ValidateJSON(data, "Theme");
        await next();
    }

    static async validateDelete(ctx: RouterContext, next: Next) {
        ValidateInput(ctx.request.body, ThemeValidator.deleteRules);
        await next();
    }
}
