import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server/index";
import { createBadRequestResponse, createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getMessageResponse } from "@server/databases/imessage/entity/Message";
import { DBMessageParams } from "@server/databases/imessage/types";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import { ChatResponse, HandleResponse } from "@server/types";

import { parseNumber } from "../../../helpers";

export class ChatRouter {
    static async count(ctx: RouterContext, _: Next) {
        const chats = await Server().iMessageRepo.getChats({ withSMS: true });
        const serviceCounts: { [key: string]: number } = {};
        for (const chat of chats) {
            if (!Object.keys(serviceCounts).includes(chat.serviceName)) {
                serviceCounts[chat.serviceName] = 0;
            }

            serviceCounts[chat.serviceName] += 1;
        }

        ctx.body = createSuccessResponse({
            total: chats.length,
            breakdown: serviceCounts
        });
    }

    static async find(ctx: RouterContext, _: Next) {
        const withQuery = ((ctx.request.query.with ?? "") as string)
            .toLowerCase()
            .split(",")
            .map(e => e.trim());
        const withParticipants = withQuery.includes("participants");
        const withLastMessage = withQuery.includes("lastmessage");

        const chats = await Server().iMessageRepo.getChats({
            chatGuid: ctx.params.guid,
            withSMS: true,
            withParticipants
        });

        if (!chats || chats.length === 0) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Chat does not exist!");
            return;
        }

        const res = await getChatResponse(chats[0]);
        if (withLastMessage) {
            res.lastMessage = await getMessageResponse(await Server().iMessageRepo.getChatLastMessage(ctx.params.guid));
        }

        ctx.body = createSuccessResponse(res);
    }

    static async getMessages(ctx: RouterContext, _: Next) {
        const withQuery = ((ctx.request.query.with ?? "") as string)
            .toLowerCase()
            .split(",")
            .map(e => e.trim());
        const withAttachments = withQuery.includes("attachment") || withQuery.includes("attachments");
        const withHandle = withQuery.includes("handle") || withQuery.includes("handles");
        const withSMS = withQuery.includes("sms");
        const sort = ["DESC", "ASC"].includes(((ctx.request.query?.sort as string) ?? "").toLowerCase())
            ? ctx.request.query?.sort
            : "DESC";
        const after = ctx.request.query?.after;
        const before = ctx.request.query?.before;

        // Pull the pagination params and make sure they are correct
        let offset = parseNumber(ctx.request.query?.offset as string) ?? 0;
        let limit = parseNumber(ctx.request.query?.limit as string) ?? 100;
        if (offset < 0) offset = 0;
        if (limit < 0 || limit > 1000) limit = 1000;

        const chats = await Server().iMessageRepo.getChats({
            chatGuid: ctx.params.guid,
            withSMS: true,
            withParticipants: false
        });

        if (!chats || chats.length === 0) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Chat does not exist!");
            return;
        }

        const opts: DBMessageParams = {
            chatGuid: ctx.params.guid,
            withAttachments,
            withHandle,
            withSMS,
            offset,
            limit,
            sort: sort as "ASC" | "DESC",
            before: Number.parseInt(before as string, 10),
            after: Number.parseInt(after as string, 10)
        };

        // Fetch the info for the message by GUID
        const messages = await Server().iMessageRepo.getMessages(opts);
        const results = [];
        for (const msg of messages ?? []) {
            results.push(await getMessageResponse(msg));
        }

        ctx.body = createSuccessResponse(results);
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the filters
        const withQuery = (body?.with ?? [])
            .filter((e: any) => typeof e === "string")
            .map((e: string) => e.toLowerCase().trim());
        const withParticipants = withQuery.includes("participants");
        const withLastMessage = withQuery.includes("lastmessage");
        const withSMS = withQuery.includes("sms");
        const withArchived = withQuery.includes("archived");
        const guid = body?.guid;
        let sort = body?.sort ?? "";

        // Validate sort param
        if (typeof sort !== "string") {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Sort parameter must be a string!");
            return;
        }

        sort = sort.toLowerCase();
        const validSorts = ["lastmessage"];
        if (!validSorts.includes(sort)) {
            sort = null;
        }

        // Pull the pagination params and make sure they are correct
        let offset = parseNumber(body?.offset as string) ?? 0;
        let limit = parseNumber(body?.limit as string) ?? 1000;
        if (offset < 0) offset = 0;
        if (limit < 0 || limit > 1000) limit = 1000;

        const chats = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
            withSMS,
            withParticipants,
            withLastMessage,
            offset,
            limit
        });

        // If the query is with the last message, it makes the participants list 1 for each chat
        // We need to fetch all the chats with their participants, then cache the participants
        // so we can merge the participant list with the chats
        const chatCache: { [key: string]: Handle[] } = {};
        const tmpChats = await Server().iMessageRepo.getChats({
            chatGuid: guid as string,
            withParticipants: true,
            withArchived,
            withSMS
        });

        for (const chat of tmpChats) {
            chatCache[chat.guid] = chat.participants;
        }

        const results = [];
        for (const chat of chats ?? []) {
            if (chat.guid.startsWith("urn:")) continue;
            const chatRes = await getChatResponse(chat);

            // Insert the cached participants from the original request
            if (Object.keys(chatCache).includes(chat.guid)) {
                chatRes.participants = await Promise.all(
                    chatCache[chat.guid].map(
                        async (e): Promise<HandleResponse> => {
                            const test = await getHandleResponse(e);
                            return test;
                        }
                    )
                );
            }

            if (withLastMessage) {
                // Set the last message, if applicable
                if (chatRes.messages && chatRes.messages.length > 0) {
                    [chatRes.lastMessage] = chatRes.messages;

                    // Remove the last message from the result
                    delete chatRes.messages;
                }
            }

            results.push(chatRes);
        }

        // If we have a sort parameter, handle the cases
        if (sort) {
            if (sort === "lastmessage" && withLastMessage) {
                results.sort((a: ChatResponse, b: ChatResponse) => {
                    const d1 = a.lastMessage?.dateCreated ?? 0;
                    const d2 = b.lastMessage?.dateCreated ?? 0;
                    if (d1 > d2) return -1;
                    if (d1 < d2) return 1;
                    return 0;
                });
            }
        }

        // Build metadata to return
        const metadata = {
            total: await Server().iMessageRepo.getChatCount(),
            offset,
            limit
        };

        ctx.body = createSuccessResponse(results, null, metadata);
    }
}
