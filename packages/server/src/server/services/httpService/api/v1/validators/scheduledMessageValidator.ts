import { RouterContext } from "koa-router";
import { Next } from "koa";
import { ValidateInput } from "./index";
import { BadRequest } from "../responses/errors";
import { ScheduledMessageScheduleType } from "@server/services/scheduledMessagesService";

export class ScheduledMessageValidator {
    static createRules = {
        type: "string|in:send-message",
        payload: "json-object",
        scheduledFor: "numeric|min:1",
        schedule: "json-object"
    };

    static async validateScheduledMessage(ctx: RouterContext, next: Next) {
        const { payload, scheduledFor, schedule } = ValidateInput(
            ctx?.request?.body,
            ScheduledMessageValidator.createRules
        );

        const required = ["chatGuid", "message", "method"];
        const missing = required.filter(key => !payload[key]);
        if (missing.length) {
            throw new BadRequest({ message: `Missing required payload fields: ${missing.join(", ")}` });
        }

        const now = new Date().getTime();
        if (scheduledFor < now) {
            throw new BadRequest({ message: `Scheduled for must be in the future` });
        }

        if (!schedule.type) {
            throw new BadRequest({ message: `Schedule type is required` });
        }

        if (
            schedule.type === ScheduledMessageScheduleType.RECURRING &&
            (!schedule.intervalType || !schedule.interval)
        ) {
            throw new BadRequest({ message: `Recurring schedule requires intervalType and interval` });
        }

        if (typeof schedule.interval !== "number") {
            throw new BadRequest({ message: `Schedule interval must be a number` });
        }

        if (schedule.interval < 1) {
            throw new BadRequest({ message: `Schedule interval must be greater than 0` });
        }

        await next();
    }
}
