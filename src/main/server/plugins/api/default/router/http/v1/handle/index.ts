import * as WS from "@trufflesuite/uws-js-unofficial";

import { GetHandlesParams } from "@server/plugins/messages_api/types";
import { IPluginTypes } from "@server/plugins/types";
import { DataTransformerPluginBase } from "@server/plugins/data_transformer/base";

import { HandleApi } from "../../../../common/handle/index";
import type { UpgradedHttp } from "../../../../types";
import { Response } from "../../../../helpers/response";

export const getHandles = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const handles = await HandleApi.getHandles(context.plugin, context.params as GetHandlesParams);

    // Get the data transformer
    const dbPlugins = (await context.plugin.getPluginsByType(
        IPluginTypes.DATA_TRANSFORMER
    )) as DataTransformerPluginBase[];
    const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;

    // Transform the data if we can
    if (dbPlugin && dbPlugin.handleSpecToApi) {
        // eslint-disable-next-line no-return-await
        Response.ok(res, await handles.map(async item => await dbPlugin.handleSpecToApi(item)));
    } else {
        Response.ok(res, handles);
    }
};

export const getHandle = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const { address } = context.params;
    if (!address) throw new Error("No address provided!");

    const handle = await HandleApi.getHandle(context.plugin, address as string, context.params as GetHandlesParams);

    // Get the data transformer
    const dbPlugins = (await context.plugin.getPluginsByType(
        IPluginTypes.DATA_TRANSFORMER
    )) as DataTransformerPluginBase[];
    const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;

    // Transform the data if we can
    if (dbPlugin && dbPlugin.handleSpecToApi) {
        // eslint-disable-next-line no-return-await
        Response.ok(res, dbPlugin.handleSpecToApi(handle));
    } else {
        Response.ok(res, handle);
    }
};
