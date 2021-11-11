import { Next } from "koa";
import { RouterContext } from "koa-router";
import { FileSystem } from "@server/fileSystem";
import { ServerInterface } from "@server/api/v1/interfaces/serverInterface";
import { GeneralInterface } from "@server/api/v1/interfaces/generalInterface";
import { Success } from "../responses/success";

export class ServerRouter {
    static async getInfo(ctx: RouterContext, _: Next) {
        return new Success(ctx, { data: GeneralInterface.getServerMetadata() }).send();
    }

    static async checkForUpdate(ctx: RouterContext, _: Next) {
        return new Success(ctx, { data: await GeneralInterface.checkForUpdate() }).send();
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
        return new Success(ctx, { data: logs }).send();
    }

    static async getStatTotals(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            params.only = (only as string).split(",");
        }

        return new Success(ctx, { data: await ServerInterface.getDatabaseTotals(params) }).send();
    }

    static async getStatMedia(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            params.only = (only as string).split(",");
        }

        return new Success(ctx, { data: await ServerInterface.getMediaTotals(params) }).send();
    }

    static async getStatMediaByChat(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            params.only = (only as string).split(",");
        }

        return new Success(ctx, { data: await await ServerInterface.getMediaTotalsByChat(params) }).send();
    }
}
