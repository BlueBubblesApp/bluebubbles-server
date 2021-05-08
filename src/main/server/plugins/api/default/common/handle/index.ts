import { IPluginTypes } from "@server/plugins/types";

import type { MessagesApiPluginBase } from "@server/plugins/messages_api/base";
import type { HandleSpec, GetHandlesParams } from "@server/specs/iMessageSpec";
import type DefaultApiPlugin from "../../index";

export class HandleApi {
    public static async getHandles(plugin: DefaultApiPlugin, params?: GetHandlesParams): Promise<HandleSpec[]> {
        const dbPlugins = (await plugin.getPluginsByType(IPluginTypes.MESSAGES_API)) as MessagesApiPluginBase[];
        const dbPlugin = dbPlugins && dbPlugins.length > 0 ? dbPlugins[0] : null;
        if (!dbPlugin) throw new Error("No Messages API plugin found!");
        return dbPlugin.getChats(params ?? {});
    }

    public static async getHandle(
        plugin: DefaultApiPlugin,
        address: string,
        params?: GetHandlesParams
    ): Promise<HandleSpec> {
        const newParams = { ...params, address };
        const chats = await HandleApi.getHandles(plugin, newParams);
        return chats && chats.length > 0 ? chats[0] : null;
    }
}
