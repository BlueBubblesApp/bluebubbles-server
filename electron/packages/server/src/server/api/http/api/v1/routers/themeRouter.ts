import { RouterContext } from "koa-router";
import { Next } from "koa";

import { isNotEmpty } from "@server/helpers/utils";
import { BackupsInterface } from "@server/api/interfaces/backupsInterface";
import { Success } from "../responses/success";

export class ThemeRouter {
    static async create(ctx: RouterContext, _: Next) {
        const { name, data } = ctx.request.body;

        // Safety to always have a name in the JSON dict if not provided
        if (!Object.keys(data).includes("name")) {
            data.name = name;
        }

        // Save the theme to a file
        await BackupsInterface.saveTheme(name, data);
        return new Success(ctx, { message: "Successfully saved theme!" }).send();
    }

    static async delete(ctx: RouterContext, _: Next) {
        const { name } = ctx.request.body;

        // Save the theme to a file
        await BackupsInterface.deleteTheme(name);
        return new Success(ctx, { message: "Successfully deleted theme!" }).send();
    }

    static async get(ctx: RouterContext, _: Next) {
        const name = ctx.query.name as string;
        let res: any;

        if (isNotEmpty(name)) {
            res = await BackupsInterface.getThemeByName(name);
            if (!res) return new Success(ctx, { message: "No theme found!" }).send();
        } else {
            res = await BackupsInterface.getAllThemes();
            if (!res) return new Success(ctx, { message: "No saved themes!" }).send();
        }

        return new Success(ctx, { message: "Successfully fetched theme(s)!", data: res }).send();
    }
}
