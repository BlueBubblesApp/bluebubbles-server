import { RouterContext } from "koa-router";
import { Next } from "koa";

import { isEmpty } from "@server/helpers/utils";
import { ContactInterface } from "@server/api/v1/interfaces/contactInterface";
import { Success } from "../responses/success";

export class ContactRouter {
    static async get(ctx: RouterContext, _: Next) {
        const extraProps = (ctx.request.query?.extraProperties as string ?? '')
            .split(',').map((e) => e.trim()).filter((e) => e && e.length > 0);
        const contacts = await ContactInterface.getAllContacts(extraProps);
        return new Success(ctx, { data: contacts }).send();
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;
        const addresses = body?.addresses ?? [];
        const extraProps = body?.extraProperties ?? [];

        let res = [];
        if (isEmpty(addresses) || !Array.isArray(addresses)) {
            res = await ContactInterface.getAllContacts(extraProps);
        } else {
            res = await ContactInterface.queryContacts(addresses, extraProps);
        }

        return new Success(ctx, { data: res }).send();
    }
}
