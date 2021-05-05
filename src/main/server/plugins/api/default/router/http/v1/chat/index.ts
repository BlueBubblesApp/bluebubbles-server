import * as WS from "@trufflesuite/uws-js-unofficial";

import { ChatSpec, GetChatsParams } from "@server/plugins/messages_api/types";
import { IPluginTypes } from "@server/plugins/types";
import { DataTransformerPluginBase } from "@server/plugins/data_transformer/base";

import { ChatApi } from "../../../../common/chat/index";
import type { UpgradedHttp } from "../../../../types";
import { Response } from "../../../../helpers/response";

export const getChats = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<void> => {
    const context = req as UpgradedHttp;
    let chats = await ChatApi.getChats(context.plugin, context.params as GetChatsParams);

    // Get the data transformer
    const dbPlugins = (await context.plugin.getPluginsByType(
        IPluginTypes.DATA_TRANSFORMER
    )) as DataTransformerPluginBase[];
    const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;

    // Transform the data if we can
    if (dbPlugin && dbPlugin.chatSpecToApi) {
        // eslint-disable-next-line no-return-await
        chats = chats.map(async item => await dbPlugin.chatSpecToApi(item));
    }

    Response.ok(res, chats);
};

export const getChat = async (res: WS.HttpResponse, req: WS.HttpRequest): Promise<ChatSpec> => {
    const context = req as UpgradedHttp;
    const { guid } = context.params;
    if (!guid) throw new Error("No Chat GUID provided!");

    const chat = await ChatApi.getChat(context.plugin, guid as string, context.params as GetChatsParams);

    // Get the data transformer
    const dbPlugins = (await context.plugin.getPluginsByType(
        IPluginTypes.DATA_TRANSFORMER
    )) as DataTransformerPluginBase[];
    const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;

    // Transform the data if we can
    if (dbPlugin && dbPlugin.chatSpecToApi) {
        // eslint-disable-next-line no-return-await
        return dbPlugin.chatSpecToApi(chat);
    }

    return chat;
};
