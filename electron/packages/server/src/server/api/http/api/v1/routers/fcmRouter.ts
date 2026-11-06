import { Next } from "koa";
import { RouterContext } from "koa-router";

import { FileSystem } from "@server/fileSystem";
import { GeneralInterface } from "@server/api/interfaces/generalInterface";
import { Success } from "../responses/success";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { NotFound } from "../responses/errors";

export class FcmRouter {
    static async getClientConfig(ctx: RouterContext, _: Next) {
        const googleServices = FileSystem.getFCMClient();
        if (isEmpty(googleServices)) {
            throw new NotFound({ error: "Google Services file not found." });
        }

        // As of May 2023, Google removed the `oauth_client[]` data from the `google-services.json` file.
        // As such, we need to manually add it back in so the client doesn't break when reading the file.
        // This is a monkeypatch. The client only requires the first part of the client_id, before the `-`.
        // This value is the same as the project number, so we can just use that.
        if (isNotEmpty(googleServices?.client) && isEmpty(googleServices?.client[0].oauth_client)) {
            googleServices.client[0].oauth_client = [
                {
                    // The project number exists in multiple fields. Fallback if the project number is not found.
                    client_id: googleServices?.project_info?.project_number ??
                        googleServices?.client[0].client_info.mobilesdk_app_id.split(":")[1],
                    client_type: 3
                }
            ];
        }

        return new Success(ctx, { data: googleServices }).send();
    }

    static async registerDevice(ctx: RouterContext, _: Next) {
        const { name, identifier } = (ctx.request?.body ?? {});
        await GeneralInterface.addFcmDevice(name, identifier);
        return new Success(ctx, { message: "Successfully added device!" }).send();
    }
}
