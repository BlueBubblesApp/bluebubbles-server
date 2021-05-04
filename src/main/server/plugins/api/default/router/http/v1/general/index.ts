import * as WS from "@trufflesuite/uws-js-unofficial";

import { Response } from "../../../../response";

export const ping = async (res: WS.HttpResponse, _: WS.HttpRequest): Promise<void> => {
    Response.ok(res, { pong: true });
};
