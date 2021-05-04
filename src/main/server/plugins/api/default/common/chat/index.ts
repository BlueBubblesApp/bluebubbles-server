import { IPluginTypes } from "@server/plugins/types";

import type { MessagesDbPluginBase } from "@server/plugins/messages_api/base";
import type { ChatSpec, GetChatsParams } from "@server/plugins/messages_api/types";
import type DefaultApiPlugin from "../../index";

export class ChatApi {
    public static async getChats(plugin: DefaultApiPlugin, params?: GetChatsParams): Promise<ChatSpec[]> {
        const dbPlugins = (await plugin.getPluginsByType(IPluginTypes.MESSAGES_DB)) as MessagesDbPluginBase[];
        const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;
        if (!dbPlugin) throw new Error("No Messages DB plugins found!");
        return dbPlugin.getChats(params ?? {});
    }

    public static async getChat(plugin: DefaultApiPlugin, guid: string, params?: GetChatsParams): Promise<ChatSpec> {
        const newParams = { ...params, guid };
        const chats = await ChatApi.getChats(plugin, newParams);
        return chats && chats.length > 0 ? chats[0] : null;
    }
}
