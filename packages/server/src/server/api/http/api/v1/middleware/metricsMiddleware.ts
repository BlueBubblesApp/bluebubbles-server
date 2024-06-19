import { Server } from "@server";
import { Context, Next } from "koa";

export const MetricsMiddleware = async (ctx: Context, next: Next) => {
    const now = new Date().getTime();
    await next();
    const later = new Date().getTime();
    Server().log(`Request to ${ctx?.request?.path?.toString() ?? "N/A"} took ${later - now} ms`, "debug");
};
