import * as WS from "@trufflesuite/uws-js-unofficial";

import { GetHandlesParams, HandleSpec } from "@server/specs/iMessageSpec";
import { IPluginTypes } from "@server/plugins/types";
import { DataTransformerPluginBase } from "@server/plugins/data_transformer/base";

import { HandleApi } from "../../../../common/handle/index";
import type { UpgradedHttp } from "../../../../types";
import { Response } from "../../../../helpers/response";

const returnData = async (res: WS.HttpResponse, messages: HandleSpec | HandleSpec[]): Promise<void> => {
    // Get the data transformer
    const dbPlugins = (await res.plugin.getPluginsByType(IPluginTypes.DATA_TRANSFORMER)) as DataTransformerPluginBase[];
    const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;

    // Transform the data if we can
    if (dbPlugin && dbPlugin.handleSpecToApi) {
        if (Array.isArray(messages)) {
            const transformed = [];
            for (const item of messages) {
                transformed.push(await dbPlugin.handleSpecToApi(item));
            }

            Response.ok(res, dbPlugin.handleSpecToApi(transformed));
        } else {
            Response.ok(res, dbPlugin.handleSpecToApi(await dbPlugin.handleSpecToApi(messages)));
        }
    } else {
        Response.ok(res, messages);
    }
};

export const getHandles = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const handles = await HandleApi.getHandles(context.plugin, context.params as GetHandlesParams);
    returnData(res, handles);
};

export const getHandle = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const { address } = context.params;
    if (!address) throw new Error("No address provided!");

    const handle = await HandleApi.getHandle(context.plugin, address as string, context.params as GetHandlesParams);
    returnData(res, handle);
};
