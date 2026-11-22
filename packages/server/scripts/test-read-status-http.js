const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { once } = require("node:events");
const Koa = require("koa");
const Router = require("koa-router");
const ts = require("typescript");

const sourceOf = file => fs.readFileSync(path.resolve(__dirname, "../src/server", file), "utf8");
const compile = source =>
    ts.transpileModule(source, {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true }
    }).outputText;
const load = (file, mocks = {}) => {
    const module = { exports: {} };
    new Function("require", "module", "exports", compile(sourceOf(file)))(
        name => (Object.hasOwn(mocks, name) ? mocks[name] : require(name)),
        module,
        module.exports
    );
    return module.exports;
};

async function testReadStatusResponse() {
    const controllers = "api/http/api/v1";
    const notifications = [];
    const readActions = [];
    const webhooks = [];
    const sockets = [];
    const suspendedPush = [];
    const server = {
        log() {},
        repo: {
            getConfig: () => "fixture-password",
            devices: () => ({ find: async () => [{ identifier: "synthetic-device" }] })
        },
        privateApi: {
            chat: {
                markRead: async guid => readActions.push({ guid, read: true }),
                markUnread: async guid => readActions.push({ guid, read: false })
            }
        },
        fcm: {
            sendNotification: async (_clients, notification) => {
                notifications.push(notification);
                await new Promise(resolve => suspendedPush.push(resolve));
            }
        },
        webhookService: { dispatch: event => webhooks.push(event) },
        logger: { debug() {} }
    };
    const context = {
        "@server": { Server: () => server },
        "@server/env": { isMinVentura: true },
        "@server/helpers/utils": {
            checkPrivateApiStatus() {},
            isNotEmpty: value => Array.isArray(value) ? value.length > 0 : Boolean(value),
            safeTrim: value => value.trim()
        }
    };

    // Execute the production notification method without constructing the Electron app.
    const serverSource = ts.createSourceFile("index.ts", sourceOf("index.ts"), ts.ScriptTarget.Latest, true);
    const serverClass = serverSource.statements.find(node =>
        ts.isClassDeclaration(node) && node.members.some(member => member.name?.getText(serverSource) === "emitMessage")
    );
    const emitMethod = serverClass.members.find(member => member.name?.getText(serverSource) === "emitMessage");
    const createNotifier = new Function("FCMService", "isNotEmpty", compile(`
        return class {
            ${emitMethod.getText(serverSource)}
        };
    `));
    const Notifier = createNotifier({ getApp: () => ({}) }, context["@server/helpers/utils"].isNotEmpty);
    server.emitMessage = Notifier.prototype.emitMessage;

    const types = load(`${controllers}/responses/types.ts`);
    const errors = load(`${controllers}/responses/errors.ts`, { "./types": types });
    const success = load(`${controllers}/responses/success.ts`, { "./types": types });
    server.httpService = {
        socketServer: { emit: (type, data) => sockets.push({ type, data }) }
    };
    const chatInterfaceImports = [
        "@server/databases/imessage/entity/Chat",
        "@server/fileSystem",
        "../apple/scripts",
        "./messageInterface",
        "../serializers/ChatSerializer",
        "@server/databases/imessage/entity/Attachment",
        "@server/databases/imessage/entity/Message",
        "../serializers/MessageSerializer"
    ];
    const fakeImports = imports => Object.fromEntries(imports.map(name => [name, {}]));
    const chatInterface = load("api/interfaces/chatInterface.ts", {
        ...context,
        ...fakeImports(chatInterfaceImports),
        "@server/events": load("events.ts")
    });
    const chatRouter = load(`${controllers}/routers/chatRouter.ts`, {
        ...context,
        ...fakeImports([
            "@server/fileSystem",
            "@server/api/serializers/MessageSerializer",
            "@server/utils/CollectionUtils",
            "../utils",
            "@server/api/serializers/ChatSerializer"
        ]),
        "@server/api/interfaces/chatInterface": chatInterface,
        "../responses/errors": errors,
        "../responses/success": success
    });

    const routeMocks = {
        ...context,
        "../../types": load("api/http/types.ts"),
        "@server/lib/logging/Loggable": { getLogger: () => ({ debug() {} }) },
        "./middleware/authMiddleware": load(`${controllers}/middleware/authMiddleware.ts`, {
            ...context,
            "../responses/errors": errors
        })
    };
    for (const name of ["log", "metrics", "privateApi"]) {
        routeMocks[`./middleware/${name}Middleware`] = load(`${controllers}/middleware/${name}Middleware.ts`, {
            ...context,
            "../responses/errors": errors
        });
    }
    // Install only the two relevant controllers' real implementations.
    const noop = async (_ctx, next) => next();
    routeMocks["./middleware/errorMiddleware"] = { ErrorMiddleware: noop };
    const routeFile = `${controllers}/httpRoutes.ts`;
    for (const [, name, filename] of sourceOf(routeFile).matchAll(/import \{ (\w+) \} from "(\.\/(?:routers|validators)\/[^"]+)";/g)) {
        routeMocks[filename] = { [name]: new Proxy({}, { get: () => noop }) };
    }
    routeMocks["./routers/chatRouter"] = chatRouter;
    const { HttpRoutes } = load(routeFile, routeMocks);
    HttpRoutes.defaultResponseTimeout = 250;
    const router = new Router();
    HttpRoutes.createRoutes(router);
    const listener = new Koa().use(router.routes()).listen(0, "127.0.0.1");
    try {
        await once(listener, "listening");
        const chat = "iMessage;-;synthetic-chat";
        const client = async action => {
            const url = `http://127.0.0.1:${listener.address().port}/api/v1/chat/${encodeURIComponent(chat)}/${action}`;
            const response = await fetch(`${url}?password=fixture-password`, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                signal: AbortSignal.timeout(2_000)
            });
            return { status: response.status, body: await response.json() };
        };
        for (const [action, read] of [["read", true], ["unread", false]]) {
            const previousCount = notifications.length;
            const response = await client(action);
            assert.deepEqual(readActions.at(-1), { guid: chat, read });
            assert.deepEqual(sockets.at(-1).data, { chatGuid: chat, read });
            assert.equal(notifications.length, previousCount + 1);
            assert.equal(response.status, 200);
            assert.equal(response.body.status, 200);
            assert.equal(webhooks.length, previousCount, "push is still unresolved when the HTTP request returns");
            suspendedPush.shift()();
            await new Promise(resolve => setImmediate(resolve));
            assert.deepEqual(webhooks.at(-1).data, { chatGuid: chat, read });
        }
        console.log("PASS: read and unread HTTP succeed independently of pending Firebase delivery");
    } finally {
        for (const resolve of suspendedPush) resolve();
        listener.closeAllConnections();
        await new Promise(resolve => listener.close(resolve));
    }
}

testReadStatusResponse().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
