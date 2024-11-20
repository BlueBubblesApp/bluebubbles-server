import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";
import { ServerError } from "../responses/errors";
import { FindMyInterface } from "@server/api/interfaces/findMyInterface";

export class FindMyRouter {
    static async refreshDevices(ctx: RouterContext, _: Next) {
        try {
            const locations = await FindMyInterface.refreshDevices();
            return new Success(ctx, {
                message: "Successfully refreshed Find My device locations!",
                data: locations
            }).send();
        } catch (ex: any) {
            throw new ServerError({
                message: "Failed to refresh Find My device locations!",
                error: ex?.message ?? ex.toString()
            });
        }
    }

    static async refreshFriends(ctx: RouterContext, _: Next) {
        try {
            const locations = await FindMyInterface.refreshFriends();
            return new Success(ctx, {
                message: "Successfully refreshed Find My friends locations!",
                data: locations
            }).send();
        } catch (ex: any) {
            throw new ServerError({
                message: "Failed to refresh Find My friends locations!",
                error: ex?.message ?? ex.toString()
            });
        }
    }

    static async devices(ctx: RouterContext, _: Next) {
        try {
            const data = await FindMyInterface.getDevices();
            return new Success(ctx, { message: "Successfully fetched Find My device locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError({
                message: "Failed to fetch Find My device locations!",
                error: ex?.message ?? ex.toString()
            });
        }
    }

    static async friends(ctx: RouterContext, _: Next) {
        try {
            const data: any = await FindMyInterface.getFriends();
            return new Success(ctx, { message: "Successfully fetched Find My friends locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError({
                message: "Failed to fetch Find My friends locations!",
                error: ex?.message ?? ex.toString()
            });
        }
    }
}
