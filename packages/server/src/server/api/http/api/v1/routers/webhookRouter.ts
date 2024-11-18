import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server";
import { isEmpty } from "@server/helpers/utils";

import { Success } from "../responses/success";
import { NotFound } from "../responses/errors";

export class WebhookRouter {
    static async get(ctx: RouterContext, _: Next) {
        const url = ctx?.request?.query?.url as string;
        const id = (ctx?.request?.query?.id) ? Number.parseInt(ctx?.request?.query?.id as string) : null;
        const webhooks = await Server().repo.getWebhooks({ url, id });

        // Convert the events to a list (from json array)
        for (const webhook of webhooks) {
            webhook.events = JSON.parse(webhook.events);
        }

        return new Success(ctx, { message: "Successfully fetched webhooks!", data: webhooks }).send();
    }

    static async create(ctx: RouterContext, _: Next) {
        const { url, events } = ctx.request.body;
        const webhook = await Server().repo.addWebhook(url, events);

        // Convert the events to a list (from json array)
        webhook.events = JSON.parse(webhook.events);

        return new Success(ctx, { data: webhook, message: "Successfully created webhook!" }).send();
    }

    static async delete(ctx: RouterContext, _: Next): Promise<void> {
        const { id } = ctx.params;

        // Find it
        const webhooks = await Server().repo.getWebhooks({ id: Number.parseInt(id as string) });
        if (isEmpty(webhooks)) throw new NotFound({ error: "Webhook does not exist!" });

        // Delete it
        await Server().repo.deleteWebhook({ id: Number.parseInt(id as string) });

        // Send success
        return new Success(ctx, { message: "Successfully deleted webhook!" }).send();
    }
}
