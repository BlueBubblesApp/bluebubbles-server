const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");
const babel = require("@babel/core");

const loadTypeScriptModule = (modulePath, overrides = {}) => {
    const transformed = babel.transformFileSync(modulePath, {
        presets: [
            [require.resolve("@babel/preset-env"), { targets: { node: "20" }, modules: "commonjs" }],
            require.resolve("@babel/preset-typescript")
        ]
    });
    const loadedModule = { exports: {} };
    const loadModule = new Function("module", "exports", "require", transformed.code);
    const customRequire = request => overrides[request] ?? require(request);
    loadModule(loadedModule, loadedModule.exports, customRequire);
    return loadedModule.exports;
};

class TestHttpError extends Error {
    constructor(response) {
        super(response?.error);
        this.response = response;
    }
}

class NotFound extends TestHttpError {
    status = 404;
}

class ServerError extends TestHttpError {
    status = 500;
}

class BadRequest extends TestHttpError {
    status = 400;
}

const attachmentRouterPath = path.join(__dirname, "../src/server/api/http/api/v1/routers/attachmentRouter.ts");

const makeAttachment = ({ guid = "attachment-guid", filePath, mimeType }) => ({
    guid,
    filePath,
    transferName: "attachment",
    originalGuid: null,
    getMimeType: () => mimeType
});

const loadAttachmentRouter = ({ attachment, privateApiEnabled = true, existingPaths = [], forceResult }) => {
    const calls = {
        forceDownload: [],
        config: [],
        fileStreams: [],
        logs: []
    };
    const server = {
        iMessageRepo: {
            getAttachment: async () => attachment
        },
        repo: {
            getConfig: key => {
                calls.config.push(key);
                return privateApiEnabled;
            }
        },
        log: (...args) => calls.logs.push(args)
    };

    class FileStream {
        constructor(ctx, filePath, mimeType) {
            calls.fileStreams.push({ ctx, filePath, mimeType });
        }

        send() {
            return "sent";
        }
    }

    const { AttachmentRouter } = loadTypeScriptModule(attachmentRouterPath, {
        electron: { nativeImage: {} },
        fs: { __esModule: true, default: { existsSync: filePath => existingPaths.includes(filePath) } },
        "@server": { Server: () => server },
        "@server/fileSystem": {
            FileSystem: {
                getRealPath: filePath => filePath
            }
        },
        "@server/databases/imessage/helpers/utils": {
            convertAudio: async () => null,
            convertImage: async () => null
        },
        "@server/helpers/utils": {
            isEmpty: value => value === null || value === undefined || value.length === 0,
            isTruthyBool: value => value === true || value === "true"
        },
        "@server/api/interfaces/attachmentInterface": {
            AttachmentInterface: {
                forceDownload: async value => {
                    calls.forceDownload.push(value);
                    return forceResult;
                }
            }
        },
        "../responses/success": {
            FileStream,
            Success: class {}
        },
        "../responses/errors": {
            BadRequest,
            NotFound,
            ServerError
        },
        "@server/api/serializers/AttachmentSerializer": {
            AttachmentSerializer: {}
        }
    });

    return { AttachmentRouter, calls };
};

const makeContext = (query = {}) => ({
    params: { guid: "attachment-guid" },
    request: { query }
});

test("restores a missing local file and streams the refreshed attachment", async () => {
    const original = makeAttachment({ filePath: "/attachments/missing.jpg", mimeType: "image/jpeg" });
    const refreshed = makeAttachment({ filePath: "/attachments/restored.png", mimeType: "image/png" });
    const { AttachmentRouter, calls } = loadAttachmentRouter({
        attachment: original,
        existingPaths: [refreshed.filePath],
        forceResult: refreshed
    });
    const ctx = makeContext({ original: "true" });

    assert.equal(await AttachmentRouter.download(ctx), "sent");
    assert.deepEqual(calls.forceDownload, [original]);
    assert.deepEqual(calls.fileStreams, [{ ctx, filePath: refreshed.filePath, mimeType: "image/png" }]);
});

test("returns not found for an absent database row without trying to force download", async () => {
    const { AttachmentRouter, calls } = loadAttachmentRouter({ attachment: null });

    await assert.rejects(AttachmentRouter.download(makeContext()), error => {
        assert.equal(error.status, 404);
        assert.equal(error.response.error, "Attachment does not exist!");
        return true;
    });
    assert.equal(calls.forceDownload.length, 0);
    assert.equal(calls.config.length, 0);
});

test("does not force download when force is false", async () => {
    const attachment = makeAttachment({ filePath: "/attachments/missing.jpg", mimeType: "image/jpeg" });
    const { AttachmentRouter, calls } = loadAttachmentRouter({ attachment, forceResult: attachment });

    await assert.rejects(AttachmentRouter.download(makeContext({ force: "false" })), error => error.status === 500);
    assert.equal(calls.forceDownload.length, 0);
    assert.equal(calls.config.length, 0);
});

test("does not force download when the Private API is disabled", async () => {
    const attachment = makeAttachment({ filePath: "/attachments/missing.jpg", mimeType: "image/jpeg" });
    const { AttachmentRouter, calls } = loadAttachmentRouter({
        attachment,
        privateApiEnabled: false,
        forceResult: attachment
    });

    await assert.rejects(AttachmentRouter.download(makeContext()), error => error.status === 500);
    assert.equal(calls.forceDownload.length, 0);
    assert.deepEqual(calls.config, ["enable_private_api"]);
});

test("returns a server error when the file is still missing after a force download", async () => {
    const original = makeAttachment({ filePath: "/attachments/missing.jpg", mimeType: "image/jpeg" });
    const refreshed = makeAttachment({ filePath: "/attachments/still-missing.jpg", mimeType: "image/jpeg" });
    const { AttachmentRouter, calls } = loadAttachmentRouter({
        attachment: original,
        forceResult: refreshed
    });

    await assert.rejects(AttachmentRouter.download(makeContext()), error => {
        assert.equal(error.status, 500);
        assert.equal(error.response.error, "Attachment does not exist in disk!");
        return true;
    });
    assert.deepEqual(calls.forceDownload, [original]);
    assert.equal(calls.fileStreams.length, 0);
});
