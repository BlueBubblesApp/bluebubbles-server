import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server/index";
import { createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getMessageResponse } from "@server/databases/imessage/entity/Message";
import { DBMessageParams } from "@server/databases/imessage/types";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { parseNumber } from "../../../helpers";

export class MessageRouter {
    static async sentCount(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount(null, null, true);
        ctx.body = createSuccessResponse({ total });
    }

    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount();
        ctx.body = createSuccessResponse({ total });
    }

    static async find(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const withQuery = ((ctx.request.query.with ?? "") as string)
            .toLowerCase()
            .split(",")
            .map(e => e.trim());
        const withChats = withQuery.includes("chats") || withQuery.includes("chat");
        const withParticipants = withQuery.includes("chats.participants") || withQuery.includes("chat.participants");

        // Fetch the info for the message by GUID
        const message = await Server().iMessageRepo.getMessage(guid, withChats);
        if (!message) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Message does not exist!");
            return;
        }

        // If we want participants of the chat, fetch them
        if (withParticipants) {
            for (const i of message.chats ?? []) {
                const chats = await Server().iMessageRepo.getChats({
                    chatGuid: i.guid,
                    withParticipants,
                    withLastMessage: false,
                    withSMS: true,
                    withArchived: true
                });

                if (!chats || chats.length === 0) continue;
                i.participants = chats[0].participants;
            }
        }

        ctx.body = createSuccessResponse(await getMessageResponse(message));
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the filters
        const withQuery = (body?.with ?? [])
            .filter((e: any) => typeof e === "string")
            .map((e: string) => e.toLowerCase().trim());
        const withChats = withQuery.includes("chat") || withQuery.includes("chats");
        const withAttachments = withQuery.includes("attachment") || withQuery.includes("attachments");
        const withHandle = withQuery.includes("handle");
        const withSMS = withQuery.includes("sms");
        const withChatParticipants =
            withQuery.includes("chat.participants") || withQuery.includes("chats.participants");
        const where = (body?.where ?? []).filter((e: any) => e.statement && e.args);
        const sort = ["DESC", "ASC"].includes((body?.sort ?? "").toLowerCase()) ? body?.sort : "DESC";
        const after = body?.after;
        const before = body?.before;
        const chatGuid = body?.chatGuid;

        // Pull the pagination params and make sure they are correct
        let offset = parseNumber(body?.offset as string) ?? 0;
        let limit = parseNumber(body?.limit as string) ?? 100;
        if (offset < 0) offset = 0;
        if (limit < 0 || limit > 1000) limit = 1000;

        if (chatGuid) {
            const chats = await Server().iMessageRepo.getChats({ chatGuid, withSMS: true });
            if (!chats || chats.length === 0) {
                ctx.body = createSuccessResponse([]);
                return;
            }
        }

        const opts: DBMessageParams = {
            chatGuid,
            withChats,
            withAttachments,
            withHandle,
            withSMS,
            offset,
            limit,
            sort,
            before,
            after
        };

        // Since we have a default value for `where`, we have to set it conditionally
        if (where && where.length > 0) {
            opts.where = where;
        }

        // Fetch the info for the message by GUID
        const messages = await Server().iMessageRepo.getMessages(opts);

        // Handle fetching the chat participants with the messages (if requested)
        const chatCache: { [key: string]: Handle[] } = {};
        if (withChats && withChatParticipants) {
            const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
            for (const i of chats) {
                chatCache[i.guid] = i.participants;
            }
        }

        // Do you want the blurhash? Default to false
        const results = [];
        for (const msg of messages) {
            // Insert in the participants from the cache
            if (withChatParticipants) {
                for (const chat of msg.chats) {
                    if (Object.keys(chatCache).includes(chat.guid)) {
                        chat.participants = chatCache[chat.guid];
                    }
                }
            }

            const msgRes = await getMessageResponse(msg, false);
            results.push(msgRes);
        }

        // Build metadata to return
        const metadata = {
            offset,
            limit
        };

        ctx.body = createSuccessResponse(results, null, metadata);
    }
}
