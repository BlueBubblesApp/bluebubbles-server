import { IPluginTypes } from "@server/plugins/types";

import type { MessagesApiPluginBase } from "@server/plugins/messages_api/base";
import type { MessageSpec, GetMessagesParams } from "@server/specs/iMessageSpec";
import type DefaultApiPlugin from "../../index";

export class MessageApi {
    public static async getMessages(plugin: DefaultApiPlugin, params?: GetMessagesParams): Promise<MessageSpec[]> {
        const dbPlugins = (await plugin.getPluginsByType(IPluginTypes.MESSAGES_API)) as MessagesApiPluginBase[];
        const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;
        if (!dbPlugin) throw new Error("No Messages API plugin found!");
        return dbPlugin.getMessages(params ?? {});
    }

    public static async getMessage(
        plugin: DefaultApiPlugin,
        guid: string,
        params?: GetMessagesParams
    ): Promise<MessageSpec> {
        const newParams = { ...params, guid };
        const messages = await MessageApi.getMessages(plugin, newParams);
        return messages && messages.length > 0 ? messages[0] : null;
    }

    public static async getUpdatedMessages(
        plugin: DefaultApiPlugin,
        params?: GetMessagesParams
    ): Promise<MessageSpec[]> {
        const dbPlugins = (await plugin.getPluginsByType(IPluginTypes.MESSAGES_API)) as MessagesApiPluginBase[];
        const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;
        if (!dbPlugin) throw new Error("No Messages API plugin found!");
        return dbPlugin.getUpdatedMessages(params ?? {});
    }
}
