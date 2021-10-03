import { RouterContext } from "koa-router";

import { FileSystem } from "@server/fileSystem";
import { createBadRequestResponse, createSuccessResponse } from "@server/helpers/responses";
import { Next } from "koa";
import { GeneralRepo } from "../interfaces/generalInterface";

export class FcmRouter {
    static async getClientConfig(ctx: RouterContext, _: Next) {
        ctx.body = createSuccessResponse(FileSystem.getFCMClient(), "Successfully got FCM data");
    }

    static async registerDevice(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        if (!body?.name || !body?.identifier) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("No device name or ID specified");
            return;
        }

        await GeneralRepo.addFcmDevice(body?.name, body?.identifier);
        ctx.body = createSuccessResponse(null, "Successfully added device!");
    }
}
