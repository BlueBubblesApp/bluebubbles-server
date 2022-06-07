import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";
import { ServerError } from "../responses/errors";
import { FindMyService } from "@server/services/findMyService";

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
            const data = await FindMyService.getFriends();
            return new Success(ctx, { message: "Successfully fetched Find My friends locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to fetch Find My friends locations!", error: ex?.message ?? ex.toString() });
        }
    }
}
