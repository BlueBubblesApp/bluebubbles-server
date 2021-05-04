import * as WS from "@trufflesuite/uws-js-unofficial";

import { AuthMiddleware } from "../../middleware/http/authMiddleware";
import { RequestParserMiddleware } from "../../middleware/http/requestParserMiddleware";
import { Response } from "../../response";
import { UpgradedHttp } from "../../types";

export class HttpRoute {
    public static v1(path: string) {
        let p = path;
        if (!p.startsWith("/")) p = `/${p}`;
        return `/api/v1${p}`;
    }

    public static base(
        ...handlers: ((res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void>)[]
    ): (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void> {
        return HttpRoute.bootstrapRouteHandlers(RequestParserMiddleware.middleware, ...handlers);
    }

    public static protected(
        ...handlers: ((res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void>)[]
    ): (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void> {
        return HttpRoute.base(AuthMiddleware.middleware, ...handlers);
    }

    private static bootstrapRouteHandlers(
        ...handlers: ((res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void>)[]
    ): (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void> {
        const handler = async (res: WS.HttpResponse, req: WS.HttpRequest) => {
            for (const func of handlers) {
                try {
                    // Call the next middleware
                    await func(res, req);

                    // If the request is marked as complete, don't continue
                    if ((req as UpgradedHttp).hasEnded) break;
                } catch (ex) {
                    console.error(ex);
                    Response.error(res, 500, ex.message);
                }
            }
        };

        return handler;
    }
}

export const onAbort = async (): Promise<void> => {
    console.log("ABORTED");
};
