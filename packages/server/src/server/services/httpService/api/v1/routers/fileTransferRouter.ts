import {RouterContext} from "koa-router";
import {Next} from "koa";

import {ServerError} from "@server/services/httpService/api/v1/responses/errors";

export class FileTransferRouter{
    static async registerFileTransfer(ctx: RouterContext, _: Next) {
      // TODO Implement
        return new ServerError( { message: "Not implemented" });
    }
}