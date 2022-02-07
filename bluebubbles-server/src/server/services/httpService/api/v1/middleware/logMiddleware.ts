import { Context, Next } from "koa";
import { Server } from "@server";

export const LogMiddleware = async (ctx: Context, next: Next) => {
    const paramStr = JSON.stringify(ctx.request.query);
    const params = JSON.parse(paramStr);

    // Strip passwords/tokens/guids
    if (Object.keys(params).includes("guid")) delete params.guid;
    if (Object.keys(params).includes("token")) delete params.token;
    if (Object.keys(params).includes("password")) delete params.password;

    const log = `Request to ${ctx.request.path.toString()} (URL Params: ${JSON.stringify(params)})`;
    Server().log(log, "debug");

    // Log the last request time to the server
    // This is used by the proxy services to not auto-refresh while we have recent connections
    Server().lastConnection = new Date().getTime();

    // Go to the next middleware
    await next();
};
