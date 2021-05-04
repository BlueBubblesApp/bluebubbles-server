import * as WS from "@trufflesuite/uws-js-unofficial";
import { Server } from "@server/index";

import { Response } from "../../../../helpers/response";
import type { UpgradedHttp } from "../../../../types";
import { Transform } from "../../../../helpers/transform";

export const getPlugins = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    // Re-brand the context with our extra stuff
    const request = req as UpgradedHttp;

    // Pull parameters and get the plugins
    const params = request.params ?? {};
    const plugins = await Server().db.plugins().find(params);
    Response.ok(
        res,
        plugins.map(item => Transform.plugin(item))
    );
};
