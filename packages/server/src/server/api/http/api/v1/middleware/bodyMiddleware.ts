import fs from "fs";
import koaBody from "koa-body";
import type { Context, Next } from "koa";

const parseBody = koaBody({
    // Increase size limits from the default 1mb
    jsonLimit: "100mb",
    textLimit: "100mb",
    formLimit: "1024mb",
    multipart: true,
    parsedMethods: ["POST", "PUT", "PATCH", "DELETE"],
    formidable: {
        // 1GB (1024 b * 1024 kb * 1024 mb)
        maxFileSize: 1024 * 1024 * 1024 // Defaults to 200mb
    }
});

/**
 * Deletes the temporary files formidable wrote for a multipart request.
 * Every route copies what it needs out of an upload before it returns, so
 * nothing needs these once the request has been handled.
 */
const removeUploadedFiles = (ctx: Context) => {
    const files = (ctx.request as any)?.files;
    if (!files || typeof files !== "object") return;

    for (const entry of Object.values(files)) {
        for (const file of Array.isArray(entry) ? entry : [entry]) {
            const tmpPath = (file as any)?.path ?? (file as any)?.filepath;
            if (typeof tmpPath === "string" && tmpPath.length > 0) {
                fs.promises.unlink(tmpPath).catch((): void => null);
            }
        }
    }
};

/**
 * Parses request bodies (JSON, text, forms, and multipart uploads).
 *
 * This runs after AuthMiddleware rather than for the whole app, so that an
 * unauthenticated request can't make the server buffer a large JSON body or
 * write multipart uploads to disk before its password has been checked.
 * Uploaded temp files are removed once the route has finished, whether it
 * succeeded or not, so uploads can't accumulate on disk.
 */
export const BodyMiddleware = async (ctx: Context, next: Next) => {
    await parseBody(ctx, async () => {
        try {
            await next();
        } finally {
            removeUploadedFiles(ctx);
        }
    });
};
