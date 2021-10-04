import { Context, Next } from "koa";
import { Server } from "@server/index";
import { createServerErrorResponse } from "@server/helpers/responses";
import { ErrorTypes } from "@server/types";

export const ErrorMiddleware = async (ctx: Context, next: Next) => {
    try {
        await next();
    } catch (ex: any) {
        Server().log(ex.message, "error");

        ctx.status = 500;
        ctx.body = createServerErrorResponse(ex.message, ErrorTypes.SERVER_ERROR, "An unhandled error has occurred!");
    }
};
