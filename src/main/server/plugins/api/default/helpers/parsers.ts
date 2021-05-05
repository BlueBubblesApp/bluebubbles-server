import * as QueryString from "querystring";
import type * as WS from "@trufflesuite/uws-js-unofficial";
import { RequestData } from "../types";

export class Parsers {
    public static queryMap: NodeJS.Dict<any> = {
        true: true,
        false: false
    };

    public static async parseRequest(req: WS.HttpRequest, res: WS.HttpResponse): Promise<RequestData> {
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

            // Normalize any values via the map
            for (const key in params) {
                try {
                    params[key] = Parsers.queryMap[params[key] as string] ?? params[key];
                } catch (ex) {
                    /* Don't really care... yet */
                }
            }
        } catch (ex) {
            console.error("Failed to parse parameters");
            console.error(ex);
        }

        return { headers, params, json };
    }

    public static readHeaders(req: WS.HttpRequest): NodeJS.Dict<string> {
        const headers: NodeJS.Dict<string> = {};
        req.forEach((k, v) => {
            headers[k] = v;
        });

        return headers;
    }

    public static async readJson(res: WS.HttpResponse): Promise<NodeJS.Dict<any>> {
        return new Promise<NodeJS.Dict<any>>((resolve, reject) => {
            let buffer: Buffer = Buffer.alloc(0);

            /* Register data cb */
            res.onData((ab, isLast) => {
                const chunk = Buffer.from(ab);

                // If this chunk is null and the entire buffer is null, there's no data
                if (chunk.length === 0 && buffer.length === 0) {
                    resolve(null);
                    return;
                }

                if (isLast) {
                    if (buffer) {
                        resolve(JSON.parse(Buffer.concat([buffer, chunk]).toString()));
                    } else {
                        resolve(JSON.parse(chunk.toString()));
                    }
                } else if (!isLast && buffer) {
                    buffer = Buffer.concat([buffer, chunk]);
                } else if (!isLast) {
                    buffer = Buffer.concat([chunk]);
                }
            });

            /* Register error cb */
            res.onAborted(reject);
        });
    }
}
