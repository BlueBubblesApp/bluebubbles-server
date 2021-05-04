import type { ChatSpec, HandleSpec, MessageSpec, AttachmentSpec } from "@server/specs/iMessageSpec";
import { IPluginConfig, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { DataTransformerPluginBase } from "../base";

const configuration: IPluginConfig = {
    name: "default",
    type: IPluginTypes.DATA_TRANSFORMER,
    displayName: "Default Data Transformer",
    description: "This is the default Data Transformer for BlueBubbles",
    version: 1,
    properties: [],
    dependencies: [] // Other plugins this depends on (<type>.<name>)
};

export default class DefaultDataTransformerPlugin extends DataTransformerPluginBase {
    constructor(args: PluginConstructorParams) {
        super({ ...args, config: configuration });
    }

    // eslint-disable-next-line class-methods-use-this
    async chatSpecToApi(data: ChatSpec): Promise<any> {
        return data;
    }

    // eslint-disable-next-line class-methods-use-this
    async handleSpecToApi(data: HandleSpec): Promise<any> {
        return data;
    }

    // eslint-disable-next-line class-methods-use-this
    async attachmentSpecToApi(data: AttachmentSpec): Promise<any> {
        return data;
    }

    // eslint-disable-next-line class-methods-use-this
    async messageSpecToApi(data: MessageSpec): Promise<any> {
        return data;
    }
}
