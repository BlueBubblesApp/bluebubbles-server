import { Server } from "@server";
import { Next } from "koa";
import { RouterContext } from "koa-router";
import { ServerError } from "../../v1/responses/errors";
import { Success } from "../../v1/responses/success";

export class TokenRouter {
    static async register(ctx: RouterContext, _: Next) {
        const {name, password, expireAt} = ctx.request.body

        const token = await Server().repo.createToken({name, password, expireAt})
        return new Success(ctx, { data: token }).send()
    }

    static async delete(ctx: RouterContext, _: Next) {
        const {name} = ctx.request.body
        const token = await Server().repo.deleteToken({name});
        return new Success(ctx, { data: token }).send()
    }

    static async refresh(ctx: RouterContext, _: Next) {
        const {name, password, expireAt} = ctx.request.body
        const serverToken = (await Server().repo.tokens().find()).find((value) => value.name == name);
        const expireAtNum = expireAt as number;
        if (!expireAtNum) {
            return new ServerError({ error: "Expire at isn't a number!"})
        }
        const newExpireAt = expireAtNum + serverToken.expireAt;

        const token = await Server().repo.updateToken({name, password, expireAt: newExpireAt })
        return new Success(ctx, { data: token }).send()
    }
}