import * as WS from "@trufflesuite/uws-js-unofficial";
import * as QueryString from "querystring";

import { Parsers } from "../../helpers/parsers";
import { UpgradedHttp } from "../../types";

export class RequestParserMiddleware {
    public static async middleware(res: WS.HttpResponse, req: WS.HttpRequest) {
        let json: NodeJS.Dict<any> = null;
        let params: NodeJS.Dict<string | string[]> = null;
        let headers: NodeJS.Dict<string> = null;
        const contentType = req.getHeader("content-type");
        const queryString = req.getQuery();

        try {
            headers = Parsers.readHeaders(req);
        } catch (ex) {
            console.error("Failed to parse headers");
            console.error(ex);
        }

        try {
            if (contentType.includes("application/json")) {
                json = await Parsers.readJson(res);
                console.log(json);
            }
        } catch (ex) {
            console.error("Failed to parse JSON");
            console.error(ex);
        }

        try {
            params = QueryString.parse(queryString);
        } catch (ex) {
            console.error("Failed to parse parameters");
            console.error(ex);
        }

        // Inject into request
        (req as UpgradedHttp).json = json;
        (req as UpgradedHttp).params = params;
        (req as UpgradedHttp).headers = headers;
    }
}
