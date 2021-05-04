import * as WS from "@trufflesuite/uws-js-unofficial";
import { Response } from "../../response";
import { SharedAuth } from "../../shared/sharedAuth";
import { UpgradedHttp } from "../../types";

export class AuthMiddleware {
    public static async middleware(res: WS.HttpResponse, req: WS.HttpRequest) {
        // Re-brand the context with our extra stuff
        const context = req as UpgradedHttp;

        const fail = (msg: string) => {
            context.hasEnded = true;
            Response.unauthorized(res, 401, msg);
        };

        // Pull out the auth token out of the headers or URL params
        const token = (context?.headers?.authorization ?? context.params.Authorization ?? "") as string;
        if (!token || token.length === 0) {
            fail('Missing "Authorization" header');
            // If the token is not valid, return a bad request
        } else {
            const dbToken = await SharedAuth.getToken(context.pluginDb, token);
            if (!dbToken) {
                fail("Invalid Token");
            } else {
                // Inject the valid auth
                context.auth = dbToken;
            }
        }
    }
}
