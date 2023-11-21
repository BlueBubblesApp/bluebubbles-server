import { Context, Next } from "koa";
import { Server } from "@server";
import { safeTrim } from "@server/helpers/utils";
import { ServerError, Unauthorized } from "../../v1/responses/errors";

export const AuthMiddleware = async (ctx: Context, next: Next) => {
    // Make sure we have a token
    const tokenRaw = ctx.get('Token');
    if (!tokenRaw) {
        Server().log(`Client (IP: ${ctx.request.ip}) attempted to access the API without a token.`, "debug");
        throw new Unauthorized({ error: "Missing token!" });
    }
    
    // Header format: "Authorization: [Token ID] [Token]"
    const tokenParts = tokenRaw.split(" ")
    const tokenID = tokenParts[0]
    const token = tokenParts[1]

    if (!tokenID) {
        Server().log(`Client (IP: ${ctx.request.ip}) attempted to access the API without a valid token ID`, "debug")
        throw new Unauthorized({ error: "Missing proper token setup!" });
    }

    // Getting the server's token that's saved then checking if the password is set
    const serverToken = (await Server().repo.tokens().find()).find((value) => value.name == tokenID);
    if (!serverToken) {
        Server().log(`Client (IP: ${ctx.request.ip}) attempted to access the API without a valid token`, "debug")
        throw new ServerError({ error: "Failed to retrieve token from the database -> does it exist?" });
    }

    const password = serverToken.password
    if (!password) {
        throw new ServerError({ error: "Failed to retrieve password from the database" });
    }

    // Now checking if the token is expired
    // Yes the + is needed to convert serverToken to a number!
    if (+serverToken.expireAt < Date.now()) {
        Server().log(`Client (IP: ${ctx.request.ip}) attempted to access the API with an expired token!`, "debug");
        // If it is we don't need it anymore!
        await Server().repo.tokens().delete(serverToken.name);
        throw new Unauthorized({ error: "Token expired!" });
    }

    // Validate the passwords match
    if (safeTrim(password) !== safeTrim(token)) {
        Server().log(`Client (IP: ${ctx.request.ip}) tried to authenticate with an incorrect password.`, "debug");
        throw new Unauthorized();
    }

    // Go to the next middleware
    await next();
};
