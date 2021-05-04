import type * as WS from "@trufflesuite/uws-js-unofficial";

export class Parsers {
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
