import { Next } from "koa";
import { RouterContext } from "koa-router";
import { createSuccessResponse } from "@server/helpers/responses";
import { FileSystem } from "@server/fileSystem";
import { GeneralRepo } from "../repository/generalRepo";
import { ServerRepo } from "../repository/serverRepo";

export class ServerRouter {
    static async getInfo(ctx: RouterContext, _: Next) {
        ctx.status = 200;
        ctx.body = createSuccessResponse(GeneralRepo.getServerMetadata());
    }

    static async checkForUpdate(ctx: RouterContext, _: Next) {
        ctx.status = 200;
        ctx.body = createSuccessResponse(await GeneralRepo.checkForUpdate());
    }

    static async getLogs(ctx: RouterContext, _: Next) {
        const countParam = ctx.request.query?.count ?? "100";
        let count;

        try {
            count = Number.parseInt(countParam as string, 10);
        } catch (ex: any) {
            count = 100;
        }

        const logs = await FileSystem.getLogs({ count });
        ctx.body = createSuccessResponse(logs);
    }

    static async getStatTotals(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            params.only = (only as string).split(",");
        }

        ctx.status = 200;
        ctx.body = createSuccessResponse(await ServerRepo.getDatabaseTotals(params));
    }

    static async getStatMedia(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            params.only = (only as string).split(",");
        }

        ctx.status = 200;
        ctx.body = createSuccessResponse(await ServerRepo.getMediaTotals(params));
    }

    static async getStatMediaByChat(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            params.only = (only as string).split(",");
        }

        ctx.status = 200;
        ctx.body = createSuccessResponse(await ServerRepo.getMediaTotalsByChat(params));
    }
}
