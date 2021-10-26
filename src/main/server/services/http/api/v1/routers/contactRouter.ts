import { RouterContext } from "koa-router";
import { Next } from "koa";

import { ContactInterface } from "../interfaces/contactInterface";
import { Success } from "../responses/success";

export class ContactRouter {
    static async get(ctx: RouterContext, _: Next) {
        const contacts = await ContactInterface.getAllContacts();
        return new Success(ctx, { data: contacts }).send();
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

        return new Success(ctx, { data: res }).send();
    }
}
