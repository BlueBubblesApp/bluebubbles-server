import { RouterContext } from "koa-router";
import { Next } from "koa";

import { createBadRequestResponse, createSuccessResponse } from "@server/helpers/responses";
import { ThemeRepo } from "../repository/themeRepo";

export class ThemeRouter {
    static async create(ctx: RouterContext, _: Next) {
        const { name, data } = ctx.request.body;

        // Validation: Name
        if (!name) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("No name provided!");
            return;
        }

        // Validation: Theme Data
        if (!data) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("No theme data provided!");
            return;
        }

        // Validation: Theme Data
        if (typeof data !== "object" || Array.isArray(data)) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Theme data must be a JSON object!");
            return;
        }

        // Safety to always have a name in the JSON dict if not provided
        if (!Object.keys(data).includes("name")) {
            data.name = name;
        }

        // Save the theme to a file
        await ThemeRepo.saveTheme(name, data);
        ctx.body = createSuccessResponse("Successfully saved theme!");
    }

    static async get(ctx: RouterContext, _: Next) {
        const name = ctx.query.name as string;
        let res: any;

        if (name && name.length > 0) {
            res = await ThemeRepo.getThemeByName(name);
        } else {
            res = await ThemeRepo.getAllThemes();
        }

        ctx.body = createSuccessResponse(res);
    }
}
