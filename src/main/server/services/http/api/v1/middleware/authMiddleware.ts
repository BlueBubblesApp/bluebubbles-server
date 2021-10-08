import { Context, Next } from "koa";
import { Server } from "@server/index";
import { createServerErrorResponse, createUnauthorizedResponse } from "@server/helpers/responses";

export const AuthMiddleware = async (ctx: Context, next: Next) => {
    const params = ctx.request.query;
    ctx.status = 401; // Default

    // Make sure we have a token
    const token = (params?.guid ?? params?.password ?? params?.token) as string;
    if (!token) {
        ctx.body = createUnauthorizedResponse();
        return;
    }

    // Make sure we have a password from the database
    const password = String(Server().repo.getConfig("password") as string);
    if (!password) {
        ctx.status = 500;
        ctx.body = createServerErrorResponse("Failed to retrieve password from the database!");
        return;
    }

    // Validate the passwords match
    if (password.trim() !== token.trim()) {
        ctx.body = createUnauthorizedResponse();
        return;
    }

    // If everything passes, await the next route
    ctx.status = 200; // Revert to 200 by default

    // Go to the next middleware
    await next();
};
