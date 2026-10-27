import { Context, Next } from "koa";
import { Server } from "@server";
import { checkServerPassword } from "@server/api/http/passwordAuth";
import { ServerError, Unauthorized } from "../responses/errors";

export const AuthMiddleware = async (ctx: Context, next: Next) => {
    const params = ctx.request.query;

    // Make sure we have a token
    const token = params?.guid ?? params?.password ?? params?.token;
    const result = checkServerPassword(token);
    if (result === "missing") {
        Server().log(`Client (IP: ${ctx.request.ip}) attempted to access the API without a token.`, "debug");
        throw new Unauthorized({ error: "Missing server password!" });
    }

    // Never authenticate anyone when no password has been configured
    if (result === "unset") {
        throw new ServerError({ error: "Failed to retrieve password from the database" });
    }

    // Validate the passwords match
    if (result !== "ok") {
        Server().log(`Client (IP: ${ctx.request.ip}) tried to authenticate with an incorrect password.`, "debug");
        throw new Unauthorized();
    }

    // Go to the next middleware
    await next();
};
