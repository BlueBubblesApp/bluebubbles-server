import { Next } from "koa";
import { RouterContext } from "koa-router";
import { createServerErrorResponse, createSuccessResponse } from "@server/helpers/responses";
import { ErrorTypes } from "@server/types";
import { MacOsInterface } from "../interfaces/macosInterface";


export class MacOsRouter {
    static async lock(ctx: RouterContext, _: Next) {
        try {
            await MacOsInterface.lock();
            ctx.body = createSuccessResponse('Successfully executed lock command!');
        } catch (ex: any) {
            ctx.status = 500;
            ctx.body = createServerErrorResponse(
                ex?.message ?? ex, ErrorTypes.SERVER_ERROR, 'Failed to execute AppleScript!');
        }
    }
}
