import { Context, Next } from "koa";
import { Server } from "@server";
import { safeTrim } from "@server/helpers/utils";
import { ServerError, Unauthorized } from "../responses/errors";

export const AuthMiddleware = async (ctx: Context, next: Next) => {
    const params = ctx.request.query;

    // Make sure we have a token
    const token = (params?.guid ?? params?.password ?? params?.token) as string;
    if (!token) {
        Server().log(`Client (IP: ${ctx.request.ip}) attempted to access the API without a token.`, "debug");
        throw new Unauthorized({ error: "Missing server password!" });
    }

    // Make sure we have a password from the database
    const password = String(Server().repo.getConfig("password") as string);
    if (!password) {
        throw new ServerError({ error: "Failed to retrieve password from the database" });
    }

    // Validate the passwords match
    if (safeTrim(password) !== safeTrim(token)) {
        Server().log(`Client (IP: ${ctx.request.ip}) tried to authenticate with an incorrect password.`, "debug");
        throw new Unauthorized();
    }

    // Go to the next middleware
    await next();
};
