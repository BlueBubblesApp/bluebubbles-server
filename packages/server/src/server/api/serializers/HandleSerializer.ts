import { HandleResponse } from "@server/types";
import { DEFAULT_CHAT_CONFIG, DEFAULT_HANDLE_CONFIG, DEFAULT_MESSAGE_CONFIG } from "./constants";
import type { HandleSerializerMutliParams, HandleSerializerSingleParams } from "./types";
import { MessageSerializer } from "./MessageSerializer";
import { ChatSerializer } from "./ChatSerializer";

export class HandleSerializer {
    static async serialize({
        handle,
        config = DEFAULT_HANDLE_CONFIG,
        messageConfig = DEFAULT_MESSAGE_CONFIG,
        chatConfig = DEFAULT_CHAT_CONFIG,
        isForNotification = false
    }: HandleSerializerSingleParams): Promise<HandleResponse> {
        return (
            await HandleSerializer.serializeList({
                handles: [handle],
                config: { ...DEFAULT_HANDLE_CONFIG, ...config },
                messageConfig: { ...DEFAULT_MESSAGE_CONFIG, ...messageConfig },
                chatConfig: { ...DEFAULT_CHAT_CONFIG, ...chatConfig },
                isForNotification
            })
        )[0];
    }

    static async serializeList({
        handles,
        config = DEFAULT_HANDLE_CONFIG,
        messageConfig = DEFAULT_MESSAGE_CONFIG,
        chatConfig = DEFAULT_CHAT_CONFIG,
        isForNotification = false
    }: HandleSerializerMutliParams): Promise<HandleResponse[]> {
        return Promise.all(
            handles.map(
                async handle =>
                    await HandleSerializer.convert({
                        handle,
                        config: { ...DEFAULT_HANDLE_CONFIG, ...config },
                        messageConfig: { ...DEFAULT_MESSAGE_CONFIG, ...messageConfig },
                        chatConfig: { ...DEFAULT_CHAT_CONFIG, ...chatConfig },
                        isForNotification
                    })
            )
        );
    }

    private static async convert({
        handle,
        config = DEFAULT_HANDLE_CONFIG,
        messageConfig = DEFAULT_MESSAGE_CONFIG,
        chatConfig = DEFAULT_CHAT_CONFIG,
        isForNotification = false
    }: HandleSerializerSingleParams): Promise<HandleResponse> {
        let output: HandleResponse = {
            originalROWID: handle.ROWID,
            address: handle.id,
            service: handle.service
        };

        if (config.includeChats) {
            output.chats = await ChatSerializer.serializeList({
                chats: handle?.chats ?? [],
                config: chatConfig,
                messageConfig,
                handleConfig: { includeChats: false, includeMessages: false },
                isForNotification
            });
        }

        if (config.includeMessages) {
            output.messages = await MessageSerializer.serializeList({
                messages: handle?.messages ?? [],
                config: messageConfig,
                isForNotification
            });
        }

        if (!isForNotification) {
            output = {
                ...output,
                ...{
                    uncanonicalizedId: handle.uncanonicalizedId,
                    country: handle.country
                }
            };
        }

        return output;
    }
}
