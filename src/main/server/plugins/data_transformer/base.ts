import { PluginBase } from "@server/plugins/base";
import type { ChatSpec, MessageSpec, AttachmentSpec, HandleSpec } from "@server/specs/iMessageSpec";

interface DataTransformerPluginBase {
    setup?(): Promise<void>;

    // API transformers
    chatSpecToApi?(chat: ChatSpec): Promise<any>;
    messageSpecToApi?(message: MessageSpec): Promise<any>;
    attachmentSpecToApi?(attachment: AttachmentSpec): Promise<any>;
    handleSpecToApi?(handle: HandleSpec): Promise<any>;

    // DB transformers
    dbToChatSpec?(data: any): Promise<ChatSpec>;
    dbToMessageSpec?(data: any): Promise<ChatSpec>;
    dbToAttachmentSpec?(data: any): Promise<ChatSpec>;
    dbToHandleSpec?(data: any): Promise<ChatSpec>;
}

class DataTransformerPluginBase extends PluginBase {
    async startup() {
        if (this.setup) await this.setup();
    }
}

export { DataTransformerPluginBase };
