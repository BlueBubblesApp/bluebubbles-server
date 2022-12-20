import { RouterContext } from "koa-router";
import { Next } from "koa";
import { ValidateInput } from "./index";
import { BadRequest } from "../responses/errors";
import { ScheduledMessageScheduleType } from "@server/services/scheduledMessagesService";

export class ScheduledMessageValidator {
    static defaultRules = {
        type: "string|in:send-message|required",
        payload: "json-object|required",
        scheduledFor: "numeric|min:1|required",
        schedule: "json-object|required"
    };

    /**
     * Validates the client inputs when creating a new scheduled message.
     *
     * @param ctx The Koa context.
     * @param next The next function.
     */
    static async validateScheduledMessage(ctx: RouterContext, next: Next) {
        const { payload, scheduledFor, schedule } = ValidateInput(
            ctx?.request?.body,
            ScheduledMessageValidator.defaultRules
        );

        const required = ["chatGuid", "message", "method"];
        const missing = required.filter(key => !payload[key]);
        if (missing.length) {
            throw new BadRequest({ error: `Missing required payload fields: ${missing.join(", ")}` });
        }

        if (typeof scheduledFor !== "number") {
            throw new BadRequest({ error: "scheduledFor must be a number" });
        }

        const now = new Date().getTime();
        if (scheduledFor < now) {
            throw new BadRequest({ error: `scheduledFor must be in the future` });
        }

        if (!schedule.type) {
            throw new BadRequest({ error: `Schedule Type is required` });
        }

        if (
            schedule.type === ScheduledMessageScheduleType.RECURRING &&
            (!schedule.intervalType || !schedule.interval)
        ) {
            throw new BadRequest({ error: `Recurring schedule requires intervalType and interval` });
        }

        if (schedule.interval && typeof schedule.interval !== "number") {
            throw new BadRequest({ error: `Schedule interval must be a number` });
        }

        if (schedule.interval && schedule.interval < 1) {
            throw new BadRequest({ error: `Schedule interval must be greater than 0` });
        }

        const intervalTypeOpts = ["hourly", "daily", "weekly", "monthly", "yearly"];
        if (schedule.intervalType && !intervalTypeOpts.includes(schedule.intervalType)) {
            throw new BadRequest({ error: `Schedule intervalType must be one of: ${intervalTypeOpts.join(", ")}` });
        }

        // Inject the converted version of scheduledFor into the request body
        ctx.request.body.scheduledFor = new Date(scheduledFor);

        await next();
    }
}
