import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server";
import { HandleInterface } from "@server/api/interfaces/handleInterface";
import { getiMessageAddressFormat, isEmpty } from "@server/helpers/utils";
import { arrayHasOne } from "@server/utils/CollectionUtils";
import { Success } from "../responses/success";
import { NotFound } from "../responses/errors";
import { parseWithQuery } from "../utils";
import { HandleSerializer } from "@server/api/serializers/HandleSerializer";

export class HandleRouter {
    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getHandleCount();
        return new Success(ctx, { data: { total } }).send();
    }

    static async find(ctx: RouterContext, _: Next) {
        const address = ctx.params.guid;
        const [handles, __] = await Server().iMessageRepo.getHandles({ address });
        if (isEmpty(handles)) throw new NotFound({ error: "Handle not found!" });
        return new Success(ctx, { data: await HandleSerializer.serialize({ handle: handles[0] }) }).send();
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the filters
        const withQuery = parseWithQuery(body?.with);
        const withChats = arrayHasOne(withQuery, ["chat", "chats"]);
        const withChatParticipants = arrayHasOne(withQuery, ["chat.participants", "chats.participants"]);
        const address = body?.address;

        // Pull the pagination params and make sure they are correct
        const offset = Number.parseInt(body?.offset, 10);
        const limit = Number.parseInt(body?.limit ?? 100, 10);

        const [results, total] = await HandleInterface.get({
            address,
            withChats,
            withChatParticipants,
            limit,
            offset
        });

        // Build metadata to return
        const metadata = {
            total,
            offset,
            limit,
            count: results.length
        };

        return new Success(ctx, { data: results, metadata }).send();
    }

    static async getFocusStatus(ctx: RouterContext, _: Next) {
        const address = ctx.params.guid;
        const addr = getiMessageAddressFormat(address);
        const [handles, __] = await Server().iMessageRepo.getHandles({ address: addr });
        if (isEmpty(handles)) throw new NotFound({ error: "Handle not found!" });

        // Get the status from the private api
        const status = await HandleInterface.getFocusStatus(handles[0]);
        return new Success(ctx, { data: { status } }).send();
    }

    static async getMessagesAvailability(ctx: RouterContext, _: Next) {
        const address = ctx.request.query?.address as string;

        // Get the availability from the private api
        const available = await HandleInterface.getMessagesAvailability(address);
        return new Success(ctx, { data: { available } }).send();
    }

    static async getFacetimeAvailability(ctx: RouterContext, _: Next) {
        const address = ctx.request.query?.address as string;

        // Get the availability from the private api
        const available = await HandleInterface.getFacetimeAvailability(address);
        return new Success(ctx, { data: { available } }).send();
    }
}
