import { Next } from "koa";
import { RouterContext } from "koa-router";
import { Success } from "../responses/success";
import { ServerError } from "../responses/errors";
import { FindMyService } from "@server/services/findMyService";

export class iCloudRouter {
    static async refresh(ctx: RouterContext, _: Next) {
        try {
            const data = await FindMyService.refresh();
            return new Success(ctx, { message: "Successfully refreshed Find My device locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to refresh Find My device locations!", error: ex?.message ?? ex.toString() });
        }
    }

    static async devices(ctx: RouterContext, _: Next) {
        try {
            const data = FindMyService.getDevices();
            return new Success(ctx, { message: "Successfully refreshed Find My device locations!", data }).send();
        } catch (ex: any) {
            throw new ServerError(
                { message: "Failed to refresh Find My device locations!", error: ex?.message ?? ex.toString() });
        }
    }
}
