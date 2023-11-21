import { Server } from "@server";
import { Next } from "koa";
import { RouterContext } from "koa-router";

export class TokenRouter {
    static async register(ctx: RouterContext, _: Next) {
        const {name, password} = ctx.request.body

        return await Server().repo.createToken({name, password})
    }

    static async delete(ctx: RouterContext, _: Next) {
        const {name} = ctx.request.body

        return await Server().repo.deleteToken({name})
    }
}