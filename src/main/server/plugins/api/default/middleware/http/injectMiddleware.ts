import * as WS from "@trufflesuite/uws-js-unofficial";

export class InjectMiddleware {
    public static middleware(meta: NodeJS.Dict<any>): (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void> {
        const retfunc = async (_: WS.HttpResponse, req: WS.HttpRequest) => {
            for (const key of Object.keys(meta)) {
                (req as NodeJS.Dict<any>)[key] = meta[key];
            }
        };

        return retfunc;
    }
}
