import { Next } from "koa";
import { RouterContext } from "koa-router";
import { ValidateInput, ValidateJSON } from ".";

export class SettingsValidator {
    static rules = {
        name: "required|string|min:3|max:50",
        data: "required"
    };

    static async validate(ctx: RouterContext, next: Next) {
        const { data } = ValidateInput(ctx.request.body, SettingsValidator.rules);
        ValidateJSON(data, "Theme");
        await next();
    }
}
