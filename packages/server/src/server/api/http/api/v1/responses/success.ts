/* eslint-disable max-classes-per-file */
import * as fs from "fs";
import { RouterContext } from "koa-router";
import { ResponseFormat, ResponseMessages, ResponseParams, ValidStatuses } from "./types";

type ResponseClasses = ResponseParams | string | fs.ReadStream;

type ResponseTypes = "json" | "html" | "file";

export class HTTPResponse {
    ctx: RouterContext;

    status: ValidStatuses;

    response: ResponseFormat;

    type: ResponseTypes;

    constructor(
        ctx: RouterContext,
        status: ValidStatuses,
        response: ResponseClasses,
        responseType: ResponseTypes = "json"
    ) {
        this.ctx = ctx;
        this.status = status;
        this.type = responseType;

        // Load the data based on the response type
        if (responseType === "json") {
            // Reload the data with conditional keys
            const res = response as ResponseParams;
            this.response = { status, message: res?.message ?? "No Message Response" };
            if (res?.data !== undefined) this.response.data = res.data;
            if (res?.metadata !== undefined) this.response.metadata = res.metadata;
        } else if (responseType === "html") {
            this.response = response as string;
        } else if (responseType === "file") {
            this.response = response as fs.ReadStream;
        }
    }

    send() {
        this.ctx.status = this.status;
        this.ctx.body = this.response;
    }

    toString() {
        if (this.type === "json") {
            const res = this.response as ResponseParams;
            return `[${this.status}] ${res?.message ?? res?.error ?? "No Response"}`;
        }

        if (this.type === "html") {
            return this.response;
        }

        if (this.type === "file") {
            return `File: ${(this.response as fs.ReadStream).readableLength} bytes`;
        }

        return "";
    }
}

export class Success extends HTTPResponse {
    constructor(ctx: RouterContext, response: ResponseParams) {
        const data: ResponseParams = { message: response?.message ?? ResponseMessages.SUCCESS };
        if (response?.data !== undefined) data.data = response.data;
        if (response?.metadata !== undefined) data.metadata = response.metadata;
        super(ctx, 200, data);
    }
}

export class FileStream extends HTTPResponse {
    constructor(ctx: RouterContext, path: string, mimeType = "application/octet-stream") {
        const src = fs.createReadStream(path);
        ctx.response.set("Content-Type", mimeType as string);
        super(ctx, 200, src, "file");
    }
}

export class HTML extends HTTPResponse {
    constructor(ctx: RouterContext, response: string) {
        super(ctx, 200, response, "html");
    }
}

export class NoData extends HTTPResponse {
    constructor(ctx: RouterContext, response: ResponseParams) {
        const data: ResponseParams = { message: response?.message ?? ResponseMessages.NO_DATA };
        super(ctx, 201, data);
    }
}
