import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";
import { ServerError } from "../responses/errors";
import { FindMyService } from "@server/services/findMyService";
import { iCloudInterface } from "@server/api/interfaces/iCloudInterface";
import { findMyInterface } from "@server/api/interfaces/findMyInterface";

export class iCloudRouter {
    static async refreshDevices(ctx: RouterContext, _: Next) {
        try {
            const data = await FindMyService.refreshDevices();
            return new Success(ctx, { message: "Successfully refreshed Find My device locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to refresh Find My device locations!", error: ex?.message ?? ex.toString() });
        }
    }

    static async refreshFriends(ctx: RouterContext, _: Next) {
        try {
            const data = await FindMyService.refreshFriends();
            return new Success(ctx, { message: "Successfully refreshed Find My friends locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to refresh Find My friends locations!", error: ex?.message ?? ex.toString() });
        }
    }

    static async devices(ctx: RouterContext, _: Next) {
        try {
            const data = await FindMyService.getDevices();
            return new Success(ctx, { message: "Successfully fetched Find My device locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to fetch Find My device locations!", error: ex?.message ?? ex.toString() });
        }
    }

    static async friends(ctx: RouterContext, _: Next) {
        try {
            const data: any = await findMyInterface.getFriends();
            return new Success(ctx, { message: "Successfully fetched Find My friends locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to fetch Find My friends locations!", error: ex?.message ?? ex.toString() });
        }
    }

    static async getAccountInfo(ctx: RouterContext, _: Next) {
        try {
            const data: any = await iCloudInterface.getAccountInfo();
            return new Success(ctx, { message: "Successfully fetched account info!", data }).send();
        } catch (ex: any) {
            throw new ServerError({ message: "Failed to fetch account info!", error: ex?.message ?? ex.toString() });
        }
    }

    static async getContactCard(ctx: RouterContext, _: Next) {
        try {
            const { address } = ctx.request.query;
            const data: any = await iCloudInterface.getContactCard(address as string);
            return new Success(ctx, { message: "Successfully fetched contact card!", data }).send();
        } catch (ex: any) {
            throw new ServerError({ message: "Failed to fetch contact card!", error: ex?.message ?? ex.toString() });
        }
    }

    static async changeAlias(ctx: RouterContext, _: Next) {
        try {
            const { alias } = ctx?.request?.body ?? {};
            const data: any = await iCloudInterface.modifyActiveAlias(alias);
            return new Success(ctx, { message: "Successfully changed iMessage Alias!", data }).send();
        } catch (ex: any) {
            throw new ServerError({ message: "Failed to change iMessage Alias", error: ex?.message ?? ex.toString() });
        }
    }
}
