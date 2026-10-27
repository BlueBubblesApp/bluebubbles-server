import { Context, Next } from "koa";
import { Server } from "@server";
import { safeTrim } from "@server/helpers/utils";
import { resolveClientAddress } from "@server/api/http/authThrottle";
import { ServerError, TooManyRequests, Unauthorized } from "../responses/errors";

export const AuthMiddleware = async (ctx: Context, next: Next) => {
    const params = ctx.request.query;
    const throttle = Server().httpService.authThrottle;
    const clientAddress = resolveClientAddress(ctx.req.socket.remoteAddress, ctx.get("x-forwarded-for"));

    // Refuse blocked clients before looking at the password, so a blocked
    // client learns nothing about its guesses
    const retryAt = throttle.retryAt(clientAddress);
    if (retryAt > 0) {
        ctx.set("Retry-After", String(Math.max(1, Math.ceil((retryAt - Date.now()) / 1000))));
        throw new TooManyRequests();
    }

    // Make sure we have a token
    const token = (params?.guid ?? params?.password ?? params?.token) as string;
    if (!token) {
        Server().log(`Client (IP: ${clientAddress}) attempted to access the API without a token.`, "debug");
        throw new Unauthorized({ error: "Missing server password!" });
    }

    // Make sure we have a password from the database
    const password = String(Server().repo.getConfig("password") as string);
    if (!password) {
        throw new ServerError({ error: "Failed to retrieve password from the database" });
    }

    // Validate the passwords match
    if (safeTrim(password) !== safeTrim(token)) {
        Server().log(`Client (IP: ${clientAddress}) tried to authenticate with an incorrect password.`, "debug");
        Server().httpService.recordAuthFailure(clientAddress, safeTrim(token));
        throw new Unauthorized();
    }

    throttle.recordSuccess(clientAddress);

    // Go to the next middleware
    await next();
};
