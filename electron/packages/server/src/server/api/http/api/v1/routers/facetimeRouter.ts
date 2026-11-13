import { Next } from "koa";
import { RouterContext } from "koa-router";
import { NoData, Success } from "../responses/success";
import { FaceTimeInterface } from "@server/api/interfaces/facetimeInterface";

export class FaceTimeRouter {
    static async answer(ctx: RouterContext, _: Next) {
        const link = await FaceTimeInterface.answer(ctx.params.call_uuid);
        return new Success(ctx, { data: { link } }).send();
    }

    static async leave(ctx: RouterContext, _: Next) {
        await FaceTimeInterface.leave(ctx.params.call_uuid);
        return new NoData(ctx, {}).send();
    }

    static async newSession(ctx: RouterContext, _: Next) {
        const link = await FaceTimeInterface.create();
        return new Success(ctx, { data: { link }}).send();
    }
}
