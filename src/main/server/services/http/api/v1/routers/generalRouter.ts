import { Next } from "koa";
import { RouterContext } from "koa-router";
import { createSuccessResponse } from "@server/helpers/responses";

export class GeneralRouter {
    static async ping(ctx: RouterContext, _: Next) {
        ctx.status = 200;
        ctx.body = createSuccessResponse("pong");
    }
}
