import { Next } from "koa";
import { RouterContext } from "koa-router";
import { MacOsInterface } from "@server/api/v1/interfaces/macosInterface";
import { Success } from "../responses/success";
import { ServerError } from "../responses/errors";

export class MacOsRouter {
    static async lock(ctx: RouterContext, _: Next) {
        try {
            await MacOsInterface.lock();
            return new Success(ctx, { message: "Successfully executed lock command!" }).send();
        } catch (ex: any) {
            throw new ServerError({ message: "Failed to execute AppleScript!", error: ex?.message ?? ex.toString() });
        }
    }

    static async restartMessagesApp(ctx: RouterContext, _: Next) {
        try {
            await MacOsInterface.restartMessagesApp();
            return new Success(ctx, { message: "Successfully executed lock command!" }).send();
        } catch (ex: any) {
            throw new ServerError({ message: "Failed to execute AppleScript!", error: ex?.message ?? ex.toString() });
        }
    }
}
