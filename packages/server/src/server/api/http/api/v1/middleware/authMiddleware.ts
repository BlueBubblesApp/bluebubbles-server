import { Context, Next } from "koa";
import { Server } from "@server";
import { checkServerPassword } from "@server/api/http/passwordAuth";
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
    const token = params?.guid ?? params?.password ?? params?.token;
    const result = checkServerPassword(token);
    if (result === "missing") {
        Server().log(`Client (IP: ${clientAddress}) attempted to access the API without a token.`, "debug");
        throw new Unauthorized({ error: "Missing server password!" });
    }

    // Never authenticate anyone when no password has been configured
    if (result === "unset") {
        throw new ServerError({ error: "Failed to retrieve password from the database" });
    }

    // Validate the passwords match
    if (result !== "ok") {
        Server().log(`Client (IP: ${clientAddress}) tried to authenticate with an incorrect password.`, "debug");
        Server().httpService.recordAuthFailure(clientAddress, String(token).trim());
        throw new Unauthorized();
    }

    throttle.recordSuccess(clientAddress);

    // Go to the next middleware
    await next();
};
