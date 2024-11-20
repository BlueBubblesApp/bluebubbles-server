import { RouterContext } from "koa-router";
import { Next } from "koa";

import { ValidateInput } from "./index";
import { BadRequest } from "../responses/errors";
import { webhookEventOptions } from "@server/api/http/constants";

export class WebhookValidator {

    static webhookValues = webhookEventOptions.map(e => e.value);

    static getWebhookRules = {
        name: "string",
        id: "number",
    };

    static async validateGetWebhooks(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.query, WebhookValidator.getWebhookRules);
        await next();
    }

    static createRules = {
        url: "required|string",
        events: "required|array"
    };

    static async validateCreateWebhook(ctx: RouterContext, next: Next) {
        ValidateInput(ctx?.request?.body, WebhookValidator.createRules);

        const { url, events } = ctx.request.body;
        if (url.length === 0) {
            throw new BadRequest({ error: "Webhook URL is required!" });
        } else if (!url.startsWith('http')) {
            throw new BadRequest({ error: "Webhook URL must include an HTTP scheme!" });
        }

        // Ensure that the events are valid
        const validatedEvents = [];
        for (const event of events) {
            if (typeof event !== "string") {
                throw new BadRequest({ error: "Webhook events must be strings!" });
            }

            // Find the webhook value in the webhook events
            const webhookEvent = webhookEventOptions.find(e => e.value === event);
            if (!webhookEvent) {
                throw new BadRequest({ error: `Invalid webhook event: ${event}! Webhook must be one of: ${WebhookValidator.webhookValues}` });
            }

            // Update the event to the label
            validatedEvents.push(webhookEvent);
        }

        // Update the events
        ctx.request.body.events = validatedEvents;

        await next();
    }
}
