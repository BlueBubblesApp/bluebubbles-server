import { Context, Next } from "koa";
import { Server } from "@server/index";
import { ErrorTypes } from "@server/services/httpService/api/v1/responses/types";
import { HTTPError } from "../responses/errors";
import { createServerErrorResponse } from "../responses";

export const ErrorMiddleware = async (ctx: Context, next: Next) => {
    try {
        await next();
    } catch (ex: any) {
        // Log the error, no matter what it is
        Server().log(`API Error: ${ex?.message ?? ex}`, "error");

        // Use the custom HTTPError handler
        if (ex instanceof HTTPError) {
            const err = ex as HTTPError;
            ctx.status = err.status;
            ctx.body = err.response;
        } else {
            ctx.status = 500;
            ctx.body = createServerErrorResponse(
                ex.message,
                ErrorTypes.SERVER_ERROR,
                "An unhandled error has occurred!"
            );
        }
    }
};
