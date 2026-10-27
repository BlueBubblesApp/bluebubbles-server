import { Context, Next } from "koa";
import { Server } from "@server";
import { isNotEmpty } from "@server/helpers/utils";

const resolve = async (chatGuid: unknown): Promise<unknown> => {
    if (typeof chatGuid !== "string" || !isNotEmpty(chatGuid)) return chatGuid;

    try {
        return await Server().iMessageRepo.resolveChatGuid(chatGuid);
    } catch (ex: any) {
        Server().log(`Failed to resolve chat GUID, "${chatGuid}": ${ex?.message ?? ex}`, "debug");
        return chatGuid;
    }
};

/**
 * Rewrites the chat GUID(s) in a request to the GUID of the matching chat in the chat.db.
 *
 * Chats can be prefixed with `any`, `iMessage`, or `SMS` (macOS Tahoe uses `any`),
 * so a client may send a GUID that differs from the stored one only by its prefix.
 *
 * @param paramIsChatGuid Whether the `:guid` route param is a chat GUID (only true for chat routes)
 */
export const ChatGuidMiddleware = (paramIsChatGuid: boolean) => {
    return async (ctx: Context, next: Next) => {
        if (paramIsChatGuid && ctx.params?.guid) {
            ctx.params.guid = await resolve(ctx.params.guid);
        }

        const body = ctx.request.body;
        if (body && typeof body === "object" && typeof body.chatGuid === "string") {
            body.chatGuid = await resolve(body.chatGuid);
        }

        const query = ctx.request.query;
        if (typeof query?.chatGuid === "string") {
            ctx.request.query = { ...query, chatGuid: (await resolve(query.chatGuid)) as string };
        }

        await next();
    };
};
