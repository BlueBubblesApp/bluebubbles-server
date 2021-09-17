import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server/index";
import { createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getHandleResponse } from "@server/databases/imessage/entity/Handle";

export class HandleRouter {
    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getHandleCount();
        ctx.body = createSuccessResponse({ total });
    }

    static async find(ctx: RouterContext, _: Next) {
        const handles = await Server().iMessageRepo.getHandles(ctx.params.guid);
        if (!handles || handles.length === 0) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Handle does not exist!");
            return;
        }

        ctx.body = createSuccessResponse(await getHandleResponse(handles[0]));
    }
}
