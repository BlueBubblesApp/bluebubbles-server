import { Server } from "@server";
import { Context, Next } from "koa";

export const TimeoutMiddleware = async (ctx: Context, next: Next) => {
    // Set timeout depending on the requested URL (default: 5 minutes)
    let timeout = 5 * 60 * 1000;

    // If the request is to send a message attachment, increase the timeout to 30 minutes
    if (ctx.request.path === "/api/v1/message/attachment") {
        timeout = 30 * 60 * 1000;
    }

    ctx.req.setTimeout(timeout, () => {
        Server().log("HTTP request timed out!", "debug");
    });

    await next();
};
