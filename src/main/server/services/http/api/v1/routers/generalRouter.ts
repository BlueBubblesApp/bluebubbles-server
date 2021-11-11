import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";

export class GeneralRouter {
    static async ping(ctx: RouterContext, _: Next) {
        return new Success(ctx, { message: "Ping received!", data: "pong" }).send();
    }
}
