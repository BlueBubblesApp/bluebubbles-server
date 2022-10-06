import { ScheduledMessagesInterface } from "@server/api/v1/interfaces/scheduledMessagesInterface";
import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";

export class ScheduledMessageRouter {
    static async getScheduledMessages(ctx: RouterContext, _: Next) {
        const data = await ScheduledMessagesInterface.getScheduledMessages();
        return new Success(ctx, { data }).send();
    }

    static async createScheduledMessage(ctx: RouterContext, _: Next) {
        const { type, payload, scheduledFor, schedule } = ctx.request.body;

        const data = await ScheduledMessagesInterface.createScheduledMessage(type, payload, scheduledFor, schedule);

        return new Success(ctx, {
            message: "Successfully created new scheduled message!",
            data
        }).send();
    }

    static async getById(ctx: RouterContext, _: Next) {
        const id = ctx.params.id;
        const data = await ScheduledMessagesInterface.getScheduledMessage(Number.parseInt(id));
        return new Success(ctx, { data }).send();
    }

    static async deleteById(ctx: RouterContext, _: Next) {
        const id = ctx.params.id;
        await ScheduledMessagesInterface.deleteScheduledMessage(Number.parseInt(id));
        return new Success(ctx, { message: "Successfully deleted scheduled message!" }).send();
    }
}
