import { Context, Next } from "koa";
import { Server } from "@server/index";
import { createServerErrorResponse } from "@server/helpers/responses";
import { ErrorTypes } from "@server/types";
import { checkPrivateApiStatus } from "@server/helpers/utils";

export const PrivateApiMiddleware = async (ctx: Context, next: Next) => {
    try {
        checkPrivateApiStatus();
        await next();
    } catch (ex: any) {
        Server().log(ex.message, "error");

        ctx.status = 500;
        ctx.body = createServerErrorResponse(
            ex.message,
            ErrorTypes.IMESSAGE_ERROR,
            "Please make sure you have completed the setup for the Private API, and your helper is connected!"
        );
    }
};
