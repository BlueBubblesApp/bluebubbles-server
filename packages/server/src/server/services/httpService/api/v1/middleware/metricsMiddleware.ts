import { Server } from "@server";
import { Context, Next } from "koa";

export const MetricsMiddleware = async (ctx: Context, next: Next) => {
    try {
        console.log("HEREE");
        const now = new Date().getTime();
        await next();
        const later = new Date().getTime();
        Server().log(`Request to ${ctx.request.path.toString()} took ${later - now} ms`);
    } catch (ex: any) {
        console.log(ex);
        // Don't do anything if there is a failure
    }
};
