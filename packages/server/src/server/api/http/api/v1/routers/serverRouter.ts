import { Next } from "koa";
import { RouterContext } from "koa-router";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { ServerInterface } from "@server/api/interfaces/serverInterface";
import { GeneralInterface } from "@server/api/interfaces/generalInterface";
import { Success } from "../responses/success";
import { AlertsInterface } from "@server/api/interfaces/alertsInterface";
import { isEmpty, isTruthyBool } from "@server/helpers/utils";
import { BadRequest } from "../responses/errors";
import { parseWithQuery } from "../utils";

export class ServerRouter {
    static async getInfo(ctx: RouterContext, _: Next) {
        return new Success(ctx, { data: await GeneralInterface.getServerMetadata() }).send();
    }

    static async checkForUpdate(ctx: RouterContext, _: Next) {
        return new Success(ctx, { data: await GeneralInterface.checkForUpdate() }).send();
    }

    static async installUpdate(ctx: RouterContext, _: Next) {
        const waitParam = (ctx.request.query?.wait ?? "false") as string;
        const wait = isTruthyBool(waitParam);

        // Check if there even is an update
        const updateMetadata = await GeneralInterface.checkForUpdate();
        if (!updateMetadata?.available) {
            throw new BadRequest({ message: "No update available!", error: "NO_UPDATE_AVAILABLE" });
        }

        // Releases without update metadata would only open a browser on the server's Mac
        if (!Server().updater.updateInfo?.canAutoInstall) {
            throw new BadRequest({
                message: `Update v${updateMetadata.metadata.version} must be installed manually!`,
                error: "UPDATE_REQUIRES_MANUAL_INSTALL"
            });
        }

        // Once the update is downloaded, it's installed and the app relaunches.
        // Ref: updateService/index.ts
        const waiter = Server().updater.installUpdate();
        if (wait) {
            Server().log("Waiting for update to download...", "debug");
            await waiter;
        }

        return new Success(ctx, { message: 'Update has started downloading!' }).send();
    }

    static async restartServices(ctx: RouterContext, _: Next) {
        // Give it a second so that we can return to the client
        setTimeout(() => {
            Server().hotRestart();
        }, 1000);

        return new Success(ctx, { message: "Successfully kicked off services restart!" }).send();
    }

    static async restartAll(ctx: RouterContext, _: Next) {
        // Give it a second so that we can return to the client
        setTimeout(() => {
            Server().relaunch();
        }, 1000);
        return new Success(ctx, { message: "Successfully kicked off re-launch process!" }).send();
    }

    static async getLogs(ctx: RouterContext, _: Next) {
        const count = FileSystem.parseLogCount(ctx.request.query?.count);
        if (count === null) {
            throw new BadRequest({ error: "Count must be a positive integer" });
        }

        const logs = await FileSystem.getLogs({ count });
        return new Success(ctx, { data: logs }).send();
    }

    static async getStatTotals(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            // Repeated params (?only=a&only=b) arrive as an array
            params.only = parseWithQuery(only, false);
        }

        return new Success(ctx, { data: await ServerInterface.getDatabaseTotals(params) }).send();
    }

    static async getStatMedia(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            // Repeated params (?only=a&only=b) arrive as an array
            params.only = parseWithQuery(only, false);
        }

        return new Success(ctx, { data: await ServerInterface.getMediaTotals(params) }).send();
    }

    static async getStatMediaByChat(ctx: RouterContext, _: Next) {
        const { only } = ctx.request.query;

        const params: any = {};
        if (only) {
            // Repeated params (?only=a&only=b) arrive as an array
            params.only = parseWithQuery(only, false);
        }

        return new Success(ctx, { data: await await ServerInterface.getMediaTotalsByChat(params) }).send();
    }

    static async getAlerts(ctx: RouterContext, _: Next) {
        return new Success(ctx, { data: await AlertsInterface.find() }).send();
    }

    static async markAsRead(ctx: RouterContext, _: Next) {
        const { ids } = ctx?.request?.body ?? {};
        if (isEmpty(ids)) throw new BadRequest({ message: 'No alert IDs provided!' });
        return new Success(ctx, { data: await AlertsInterface.markAsRead(ids) }).send();
    }
}
