import { Context, Next } from "koa";
import { Server } from "@server";
import { safeTrim } from "@server/helpers/utils";
import { ServerError, Unauthorized } from "../responses/errors";

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
        Server().log(`Client (IP: ${ctx.request.ip} attempted to access the API without a valid token ID)`, "debug")
        throw new Unauthorized({ error: "Missing proper token setup!" });
    }

    if (!tokenID) {
        Server().log(`Client (IP: ${ctx.request.ip} attempted to access the API without a valid token)`, "debug")
        throw new Unauthorized({ error: "Missing proper token setup!" });
    }

    // Make sure we have a password from the database
    // const password = String(Server().repo.getConfig(`token-${tokenID}`) as string);
    const password = (await Server().repo.tokens().find()).find((value) => value.name == tokenID).password;
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
