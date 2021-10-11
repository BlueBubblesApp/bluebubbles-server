import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server/index";
import { createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getHandleResponse } from "@server/databases/imessage/entity/Handle";
import { parseNumber } from "@server/services/http/helpers";
import { HandleInterface } from "../interfaces/handleInterface";

export class HandleRouter {
    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getHandleCount();
        ctx.body = createSuccessResponse({ total });
    }

    static async find(ctx: RouterContext, _: Next) {
        const address = ctx.params.guid;
        const handles = await Server().iMessageRepo.getHandles({ address });
        if (!handles || handles.length === 0) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Handle does not exist!");
            return;
        }

        ctx.body = createSuccessResponse(await getHandleResponse(handles[0]));
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the filters
        const withQuery = (body?.with ?? [])
            .filter((e: any) => typeof e === "string")
            .map((e: string) => e.toLowerCase().trim());
        const withChats = withQuery.includes("chat") || withQuery.includes("chats");
        const withChatParticipants =
            withQuery.includes("chat.participants") || withQuery.includes("chats.participants");
        const address = body?.address;

        // Pull the pagination params and make sure they are correct
        let offset = parseNumber(body?.offset as string) ?? 0;
        let limit = parseNumber(body?.limit as string) ?? 100;
        if (offset < 0) offset = 0;
        if (limit < 0 || limit > 1000) limit = 1000;

        // Build metadata to return
        const metadata = {
            total: await Server().iMessageRepo.getHandleCount(),
            offset,
            limit
        };

        const results = await HandleInterface.get({
            address,
            withChats,
            withChatParticipants,
            limit,
            offset
        });

        ctx.body = createSuccessResponse(results, null, metadata);
    }
}
