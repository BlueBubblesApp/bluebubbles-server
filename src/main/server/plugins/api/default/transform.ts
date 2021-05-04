import { Plugin } from "@server/databases/server/entity";
import { IPluginConfigPropItem } from "@server/plugins/types";

export class Transform {
    public static plugin(plugin: Plugin) {
        const output = {
            id: plugin.id,
            name: plugin.name,
            type: plugin.type,
            displayName: plugin.displayName,
            description: plugin.description,
            enabled: plugin.enabled,
            properties: plugin.properties,
            version: plugin.version
        };

        // Strip out values from properties
        // Right now, i don't think I want values exposed
        for (let i = 0; i < (output.properties as IPluginConfigPropItem[]).length; i += 1) {
            if (Object.keys((output.properties as IPluginConfigPropItem[])[i]).includes("value")) {
                delete (output.properties as IPluginConfigPropItem[])[i].value;
            }
        }

        return output;
    }
}
