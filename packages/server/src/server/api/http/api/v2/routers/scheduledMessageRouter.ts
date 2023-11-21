import { ScheduledMessagesInterface } from "@server/api/interfaces/scheduledMessagesInterface";
import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";

export class ScheduledMessageRouter {
    /**
     * HTTP route for handling the fetching of all scheduled messages.
     *
     * @param ctx The Koa context.
     * @param _ The next function.
     */
    static async getScheduledMessages(ctx: RouterContext, _: Next) {
        const data = await ScheduledMessagesInterface.getScheduledMessages();
        return new Success(ctx, { data }).send();
    }

    /**
     * HTTP route for handling the creation of a new scheduled message.
     *
     * @param ctx The Koa context.
     * @param _ The next function.
     */
    static async createScheduledMessage(ctx: RouterContext, _: Next) {
        const { type, payload, scheduledFor, schedule } = ctx.request.body;

        const data = await ScheduledMessagesInterface.createScheduledMessage(type, payload, scheduledFor, schedule);

        return new Success(ctx, {
            message: "Successfully created new scheduled message!",
            data
        }).send();
    }

    /**
     * HTTP route for handling the updating an existing scheduled message
     *
     * @param ctx The Koa context.
     * @param _ The next function.
     */
    static async updateScheduledMessage(ctx: RouterContext, _: Next) {
        const id = ctx.params.id;
        const { type, payload, scheduledFor, schedule } = ctx.request.body;

        const data = await ScheduledMessagesInterface.updateScheduledMessage(
            Number.parseInt(id),
            type,
            payload,
            scheduledFor,
            schedule
        );

        return new Success(ctx, {
            message: "Successfully updated the scheduled message!",
            data
        }).send();
    }

    /**
     * HTTP route for handling fetching a single scheduled message.
     *
     * @param ctx The Koa context.
     * @param _ The next function.
     */
    static async getById(ctx: RouterContext, _: Next) {
        const id = ctx.params.id;
        const data = await ScheduledMessagesInterface.getScheduledMessage(Number.parseInt(id));
        return new Success(ctx, { data }).send();
    }

    /**
     * HTTP route for handling the deletion of a single scheduled message.
     *
     * @param ctx The Koa context.
     * @param _ The next function.
     */
    static async deleteById(ctx: RouterContext, _: Next) {
        const id = ctx.params.id;
        await ScheduledMessagesInterface.deleteScheduledMessage(Number.parseInt(id));
        return new Success(ctx, { message: "Successfully deleted scheduled message!" }).send();
    }
}
