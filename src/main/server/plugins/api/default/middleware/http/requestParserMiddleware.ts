import * as WS from "@trufflesuite/uws-js-unofficial";
import * as QueryString from "querystring";

import { Parsers } from "../../helpers/parsers";
import { UpgradedHttp } from "../../types";

export class RequestParserMiddleware {
    public static async middleware(res: WS.HttpResponse, req: WS.HttpRequest) {
        try {
            const parsed = await Parsers.parseRequest(req, res);

            // Inject into request
            (req as UpgradedHttp).json = parsed.json;
            (req as UpgradedHttp).params = parsed.params;
            (req as UpgradedHttp).headers = parsed.headers;
        } catch (ex) {
            console.error(ex);
        }
    }
}
