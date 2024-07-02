import { Context, Next } from "koa";
import { Server } from "@server";
import { ErrorTypes } from "@server/api/http/api/v1/responses/types";
import { HTTPError } from "../responses/errors";
import { createServerErrorResponse } from "../responses";

export const ErrorMiddleware = async (ctx: Context, next: Next) => {
    try {
        await next();
    } catch (ex: any) {
        Server().log(`Raw Error: ${String(ex)}`, "debug");

        // Log the error, no matter what it is
        let errStr = `API Error: ${ex?.message ?? ex}`;
        if (ex?.response?.error?.message) {
            errStr = `${errStr} -> ${ex?.response?.error?.message}`;
        }
        if (ex?.data) {
            errStr = `${errStr} (has data: true)`;
        }

        Server().log(errStr, "debug");
        if (ex?.stack) {
            Server().log(ex?.stack, "debug");
        }

        // Use the custom HTTPError handler
        if (ex instanceof HTTPError) {
            const err = ex as HTTPError;
            ctx.status = err.status;
            ctx.body = err.response;
        } else {
            ctx.status = 500;
            ctx.body = createServerErrorResponse(
                ex?.message ?? String(ex),
                ErrorTypes.SERVER_ERROR,
                "An unhandled error has occurred!"
            );
        }
    }
};
