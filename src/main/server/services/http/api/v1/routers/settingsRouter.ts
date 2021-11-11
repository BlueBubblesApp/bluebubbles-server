import { RouterContext } from "koa-router";
import { Next } from "koa";

import { isNotEmpty } from "@server/helpers/utils";
import { BackupsInterface } from "@server/api/v1/interfaces/backupsInterface";
import { ValidateInput, ValidateJSON } from "../validators";
import { SettingsValidator } from "../validators/settingsValidator";
import { Success } from "../responses/success";

export class SettingsRouter {
    static async create(ctx: RouterContext, _: Next) {
        // Validation
        const { name, data } = ValidateInput(ctx.request.body, SettingsValidator.rules);
        ValidateJSON(data, "Settings");

        // Safety to always have a name in the JSON dict if not provided
        if (!Object.keys(data).includes("name")) {
            data.name = name;
        }

        // Save the settings to a file
        await BackupsInterface.saveSettings(name, data);
        return new Success(ctx, { message: "Successfully saved settings!" }).send();
    }

    static async get(ctx: RouterContext, _: Next) {
        const name = ctx.query.name as string;
        let res: any;

        if (isNotEmpty(name)) {
            res = await BackupsInterface.getSettingsByName(name);
            if (!res) return new Success(ctx, { message: "No settings found!" }).send();
        } else {
            res = await BackupsInterface.getAllSettings();
            if (!res) return new Success(ctx, { message: "No saved settings!" }).send();
        }

        return new Success(ctx, { message: "Successfully fetched settings!", data: res }).send();
    }
}
