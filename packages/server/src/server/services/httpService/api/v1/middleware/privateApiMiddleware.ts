import { Context, Next } from "koa";
import { checkPrivateApiStatus } from "@server/helpers/utils";
import { IMessageError } from "../responses/errors";

export const PrivateApiMiddleware = async (ctx: Context, next: Next) => {
    try {
        checkPrivateApiStatus();
    } catch (ex: any) {
        // Re-throw the error as an iMessage error
        throw new IMessageError({
            message: "Please make sure you have completed the setup for the Private API, and your helper is connected!",
            error: ex.message
        });
    }

    await next();
};
