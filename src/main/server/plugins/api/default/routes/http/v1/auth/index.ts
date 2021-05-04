import * as WS from "@trufflesuite/uws-js-unofficial";

import { Response } from "../../../../response";
import type { UpgradedHttp } from "../../../../types";
import type { PasswordAuthBody, RefreshAuthBody } from "../../../shared/types";
import { SharedAuth } from "../../../../shared/sharedAuth";

export const tokenAuth = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    // Re-brand the context with our extra stuff
    const request = req as UpgradedHttp;

    // Pull out the authentication type (or default to password)
    const grantType = request?.params?.grant_type ?? "password";
    const name = ((request.json as PasswordAuthBody)?.name as string) ?? "api-client";

    const fail = (msg: string) => {
        request.hasEnded = true;
        Response.badRequest(res, 400, msg);
    };

    // Handle authentication based on the grant type
    if (grantType === "password") {
        const password = (request?.json as PasswordAuthBody)?.password as string;
        if (!password) {
            fail("A `password` is required to authenticate");
        } else {
            // Get the password from the DB
            const storedPassword = request.plugin.getProperty("password") as string;
            if (password !== storedPassword) {
                fail("Incorrect Password");
            } else {
                // If the password is correct, generate a new token and return it
                const jwt = await SharedAuth.createNewToken(request.pluginDb, request.plugin, name);
                Response.ok(res, { jwt });
            }
        }
    } else if (grantType === "refresh_token") {
        const token = (request?.json as RefreshAuthBody)?.token as string;
        if (!token) {
            fail("A `token` is required to re-authenticate!");
        } else {
            const jwt = await SharedAuth.refreshToken(request.pluginDb, request.plugin, token);
            Response.ok(res, { jwt });
        }
    } else {
        fail("Invalid `grant_type` parameter!");
    }
};
