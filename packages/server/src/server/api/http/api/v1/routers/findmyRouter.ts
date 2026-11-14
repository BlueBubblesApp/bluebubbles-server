import { isMinSequoia } from "@server/env";
import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";
import { ServerError, ServiceUnavailable } from "../responses/errors";
import { FindMyInterface } from "@server/api/interfaces/findMyInterface";
import { FindMyFriendLocation } from "@server/api/lib/findmy/types";
import { NEW_FINDMY_LOCATION } from "@server/events";
import { Server } from "@server";
import { FindMyUnavailableError } from "@server/api/privateApi/FindMyHelperReadiness";

export class FindMyRouter {
    static async status(ctx: RouterContext, _: Next) {
        const readiness = Server().privateApi.findMyReadiness;
        return new Success(ctx, {
            message: "Find My helper status",
            data: {
                ...readiness,
                privateApiEnabled: Boolean(Server().repo.getConfig("enable_private_api")),
                helperRequired: isMinSequoia,
                helperConnected: readiness.status === "ready" && Server().privateApi.hasClient("com.apple.findmy"),
                cachedFriends: Server().findMyFriendsCache.getAll().length,
                cachedDevices: Server().findMyDevicesCache.getAll().length
            }
        }).send();
    }

    static async retry(ctx: RouterContext, _: Next) {
        const readiness = await Server().privateApi.retryFindMy();
        return new Success(ctx, { message: "Find My helper availability check requested", data: readiness }).send();
    }

    static async emitFriendLocationUpdates(friendLocations: FindMyFriendLocation[]) {
        if (!Array.isArray(friendLocations)) return;
        for (const friendLocation of friendLocations) {
            await Server().emitMessage(NEW_FINDMY_LOCATION, friendLocation, "normal", false, true);
        }

        Server().logger.debug(
            `Emitted ${friendLocations.length} FindMy friend location update(s) to socket clients after refresh.`
        );
    }

    static async refreshDevices(ctx: RouterContext, _: Next) {
        try {
            const locations = await FindMyInterface.refreshDevices();
            return new Success(ctx, {
                message: "Successfully refreshed Find My device locations!",
                data: locations
            }).send();
        } catch (ex: any) {
            if (ex instanceof FindMyUnavailableError) {
                throw new ServiceUnavailable({ error: ex.message, data: ex.readiness });
            }
            throw new ServerError({
                message: "Failed to refresh Find My device locations!",
                error: ex?.message ?? ex.toString()
            });
        }
    }

    static async refreshFriends(ctx: RouterContext, _: Next) {
        try {
            const friendLocations = await FindMyInterface.refreshFriends(true, true);
            await FindMyRouter.emitFriendLocationUpdates(friendLocations);
            return new Success(ctx, {
                message: "Successfully refreshed Find My friends locations!",
                data: friendLocations
            }).send();
        } catch (ex: any) {
            if (ex instanceof FindMyUnavailableError) {
                throw new ServiceUnavailable({ error: ex.message, data: ex.readiness });
            }
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
            const friendLocations = await FindMyInterface.getFriends();
            return new Success(ctx, {
                message: "Successfully fetched Find My friends locations!",
                data: friendLocations
            }).send();
        } catch (ex: any) {
            throw new ServerError({
                message: "Failed to fetch Find My friends locations!",
                error: ex?.message ?? ex.toString()
            });
        }
    }
}
