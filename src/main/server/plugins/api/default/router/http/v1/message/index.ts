import * as WS from "@trufflesuite/uws-js-unofficial";

import { MessageSpec, GetMessagesParams } from "@server/specs/iMessageSpec";
import { IPluginTypes } from "@server/plugins/types";
import { DataTransformerPluginBase } from "@server/plugins/data_transformer/base";

import { MessageApi } from "../../../../common/message/index";
import type { UpgradedHttp } from "../../../../types";
import { Response } from "../../../../helpers/response";

const returnData = async (res: WS.HttpResponse, messages: MessageSpec | MessageSpec[]): Promise<void> => {
    // Get the data transformer
    const dbPlugins = (await res.plugin.getPluginsByType(IPluginTypes.DATA_TRANSFORMER)) as DataTransformerPluginBase[];
    const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;

    // Transform the data if we can
    if (dbPlugin && dbPlugin.messageSpecToApi) {
        if (Array.isArray(messages)) {
            const transformed = [];
            for (const item of messages) {
                transformed.push(await dbPlugin.messageSpecToApi(item));
            }

            Response.ok(res, dbPlugin.messageSpecToApi(transformed));
        } else {
            Response.ok(res, dbPlugin.messageSpecToApi(await dbPlugin.messageSpecToApi(messages)));
        }
    } else {
        Response.ok(res, messages);
    }
};

export const getMessages = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const messages = await MessageApi.getMessages(context.plugin, context.params as GetMessagesParams);
    returnData(res, messages);
};

export const getMessage = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const { guid } = context.params;
    if (!guid) throw new Error("No Message GUID provided!");

    const message = await MessageApi.getMessage(context.plugin, guid as string, context.params as GetMessagesParams);
    returnData(res, message);
};

export const getUpdatedMessages = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    const messages = await MessageApi.getUpdatedMessages(context.plugin, context.params as GetMessagesParams);
    returnData(res, messages);
};
