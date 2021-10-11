import { RouterContext } from "koa-router";
import { Next } from "koa";

import { createSuccessResponse } from "@server/helpers/responses";
import { ContactInterface } from "../interfaces/contactInterface";

export class ContactRouter {
    static async get(ctx: RouterContext, _: Next) {
        const contacts = await ContactInterface.getAllContacts();
        ctx.body = createSuccessResponse(contacts);
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;
        const addresses = body?.addresses ?? [];

        let res = [];
        if (!addresses || !Array.isArray(addresses) || addresses.length === 0) {
            res = await ContactInterface.getAllContacts();
        } else {
            res = await ContactInterface.queryContacts(addresses);
        }

        ctx.body = createSuccessResponse(res);
    }
}
