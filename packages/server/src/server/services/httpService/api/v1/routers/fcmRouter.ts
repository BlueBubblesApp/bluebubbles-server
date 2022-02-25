import { Next } from "koa";
import { RouterContext } from "koa-router";

import { FileSystem } from "@server/fileSystem";
import { GeneralInterface } from "@server/api/v1/interfaces/generalInterface";
import { Success } from "../responses/success";

export class FcmRouter {
    static async getClientConfig(ctx: RouterContext, _: Next) {
        return new Success(ctx, { data: FileSystem.getFCMClient() }).send();
    }

    static async registerDevice(ctx: RouterContext, _: Next) {
        const { name, identifier } = ctx.request?.body;
        await GeneralInterface.addFcmDevice(name, identifier);
        return new Success(ctx, { message: "Successfully added device!" }).send();
    }
}
