const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const ts = require("typescript");

const load = (file, mocks = {}, globals = {}) => {
    const filename = path.resolve(__dirname, file);
    const source = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
        fileName: filename
    }).outputText;
    const module = { exports: {} };
    new Function("require", "module", "exports", ...Object.keys(globals), source)(
        name => (Object.prototype.hasOwnProperty.call(mocks, name) ? mocks[name] : require(name)),
        module,
        module.exports,
        ...Object.values(globals)
    );
    return module.exports;
};

const readinessModule = load("../src/server/api/privateApi/FindMyHelperReadiness.ts");
const flush = async () => {
    for (let count = 0; count < 20; count += 1) await Promise.resolve();
};
const logging = {
    Loggable: class {
        log = { debug() {}, warn() {}, error() {} };
    }
};

const createEnvironment = ({
    ignoreTerm = false,
    neverStops = false,
    permissionPending = false,
    oldRegistration = false
} = {}) => {
    const timers = new Map();
    const clock = {
        setTimeout(callback, delay) {
            const key = {};
            timers.set(key, { callback, delay });
            return key;
        },
        clearTimeout(key) {
            timers.delete(key);
        },
        fire(delay) {
            for (const [key, timer] of [...timers]) {
                if (timer.delay === delay) {
                    timers.delete(key);
                    timer.callback();
                }
            }
        },
        count(delay) {
            return [...timers.values()].filter(timer => timer.delay === delay).length;
        }
    };
    const config = { enable_private_api: true, open_findmy_on_startup: true };
    // Messages is already working under this same system configuration.
    const clients = new Set(["com.apple.MobileSMS"]);
    const privateApi = new EventEmitter();
    privateApi.hasClient = process => clients.has(process);
    const spawners = [];
    class ProcessSpawner {
        killed = 0;
        settled = false;
        signals = [];
        constructor(options) {
            this.options = options;
        }
        execute() {
            spawners.push(this);
            return new Promise((resolve, reject) => {
                this.resolve = resolve;
                this.reject = reject;
            });
        }
        async kill(signal = "SIGTERM") {
            this.killed += 1;
            this.signals.push(signal);
            if (neverStops || (ignoreTerm && signal === "SIGTERM")) return;
            if (this.settled) return;
            this.settled = true;
            if (this.options.logTag === "FindMy") clients.delete("com.apple.findmy");
            this.reject({ message: "Test child terminated" });
        }
        exit() {
            this.settled = true;
            this.resolve(this);
        }
    }
    const server = {
        repo: { getConfig: name => config[name] },
        privateApi,
        findMyFriendsCache: { getAll: () => [{}] },
        findMyDevicesCache: { getAll: () => [{}] }
    };
    const fileSystem = {
        FileSystem: {
            resources: "/resources",
            requestFindMyAutomationPermissions: async signal => {
                if (!permissionPending) return;
                await new Promise((resolve, reject) => {
                    signal.addEventListener("abort", () => reject(new Error("Test permission request cancelled")), {
                        once: true
                    });
                });
            },
            executeAppleScript: async () => {},
            killProcess: async app => {
                if (app === "FindMy" && oldRegistration) {
                    oldRegistration = false;
                    clients.add("com.apple.findmy");
                    privateApi.emit("client-registered", { process: "com.apple.findmy" });
                }
                for (const spawner of spawners) {
                    if (!spawner.settled && spawner.options.logTag === app) await spawner.kill();
                }
            }
        }
    };
    const baseMocks = {
        "@server": { Server: () => server },
        "@server/helpers/utils": { waitMs: async () => {} },
        "@server/fileSystem": fileSystem,
        "@server/api/apple/scripts": { hideApp: () => "" },
        "@server/lib/logging/Loggable": logging,
        "@server/lib/ProcessSpawner": { ProcessSpawner }
    };
    const { DylibPlugin } = load("../src/server/api/privateApi/modes/dylibPlugins/index.ts", baseMocks, clock);
    const sharedMocks = {
        ".": { DylibPlugin },
        "@server": { Server: () => server },
        "@server/env": { isMinSequoia: true, isMinBigSur: true, isMinMonterey: true },
        "@server/fileSystem": fileSystem,
        "@server/api/interfaces/findMyInterface": {
            FindMyInterface: { refreshFriends: async () => [], refreshDevices: async () => [] }
        },
        "@server/api/privateApi/FindMyHelperReadiness": readinessModule
    };
    const { FindMyDylibPlugin } = load(
        "../src/server/api/privateApi/modes/dylibPlugins/FindMyDylibPlugin.ts",
        sharedMocks,
        clock
    );
    const { MessagesDylibPlugin } = load(
        "../src/server/api/privateApi/modes/dylibPlugins/MessagesDylibPlugin.ts",
        sharedMocks,
        clock
    );
    class FindMy extends FindMyDylibPlugin {
        get parentProcessPath() {
            return "/test/FindMy";
        }
    }
    class Messages extends MessagesDylibPlugin {
        get parentProcessPath() {
            return "/test/Messages";
        }
    }
    return {
        clock,
        config,
        clients,
        privateApi,
        spawners,
        findMy: new FindMy("Find My"),
        messages: new Messages("Messages"),
        register(process) {
            clients.add(process);
            privateApi.emit("client-registered", { process });
        }
    };
};

const testLifecycle = async () => {
    const env = createEnvironment();
    const messagesRun = env.messages.injectPlugin();
    const findMyRun = env.findMy.injectPlugin();
    await flush();
    assert.equal(env.findMy.readiness.status, "initializing");
    assert.equal(env.clock.count(30_000), 1, "only Find My must have a registration deadline");
    const messagesChild = env.spawners.find(value => value.options.logTag === "Messages");
    const findMyChild = env.spawners.find(value => value.options.logTag === "FindMy");
    env.register("com.apple.MobileSMS");
    assert.equal(env.findMy.readiness.status, "initializing", "Messages registration must not enable Find My");

    env.clock.fire(30_000);
    await flush();
    await findMyRun;
    assert.equal(env.findMy.readiness.status, "unavailable");
    assert.equal(env.findMy.readiness.reason, "registration_timeout");
    assert.equal(findMyChild.killed, 1, "timeout must stop the child created by this attempt");
    assert.equal(messagesChild.killed, 0, "Find My timeout must not stop Messages");
    assert.equal(env.clients.has("com.apple.MobileSMS"), true);
    const spawnedBeforeRetry = env.spawners.length;
    await env.findMy.injectPlugin();
    assert.equal(env.spawners.length, spawnedBeforeRetry, "a timed-out helper must not automatically retry");
    env.register("com.apple.findmy");
    assert.equal(
        env.findMy.readiness.status,
        "unavailable",
        "a late registration cannot resurrect the expired attempt"
    );

    await env.findMy.retry();
    await flush();
    assert.equal(env.findMy.readiness.status, "initializing");
    assert.equal(env.spawners.length, spawnedBeforeRetry + 1, "explicit retry starts exactly one new attempt");
    env.register("com.apple.findmy");
    await flush();
    assert.equal(env.findMy.readiness.status, "ready");
    assert.equal(env.clock.count(30_000), 0, "successful registration must cancel the deadline");
    env.clients.delete("com.apple.findmy");
    assert.equal(env.findMy.readiness.status, "unavailable");
    assert.equal(env.findMy.readiness.reason, "connection_lost");
    env.register("com.apple.findmy");
    assert.equal(env.findMy.readiness.status, "ready", "a live attempt may recover its helper socket");

    env.config.open_findmy_on_startup = false;
    await env.findMy.stop();
    await flush();
    assert.equal(env.findMy.readiness.status, "disabled");
    assert.equal(messagesChild.killed, 0, "the Find My preference must leave Messages running");
    env.config.open_findmy_on_startup = true;
    await env.findMy.retry();
    await flush();
    assert.equal(env.findMy.readiness.status, "initializing");
    env.register("com.apple.findmy");
    assert.equal(env.findMy.readiness.status, "ready");
    env.config.open_findmy_on_startup = false;
    await env.findMy.stop();

    // Existing Messages supervision still restarts a normally exited host.
    const beforeMessagesExit = env.spawners.length;
    messagesChild.exit();
    await flush();
    assert.equal(env.spawners.length, beforeMessagesExit + 1);
    env.config.enable_private_api = false;
    await env.messages.stop();
    await messagesRun;
    assert.equal(env.clock.count(30_000), 0);
    assert.equal(env.privateApi.listenerCount("client-registered"), 0, "all lifecycle listeners must be removed");
};

const testExitBeforeRegistration = async () => {
    const env = createEnvironment();
    const run = env.findMy.injectPlugin();
    await flush();
    env.spawners[0].exit();
    await run;
    assert.equal(env.findMy.readiness.status, "unavailable");
    assert.equal(env.findMy.readiness.reason, "launch_failed");
    assert.equal(env.spawners.length, 1, "an unregistered clean exit must not create a restart loop");
    assert.equal(env.clock.count(30_000), 0);
    assert.equal(env.privateApi.listenerCount("client-registered"), 0);
};

const testBoundedTermination = async () => {
    const env = createEnvironment({ ignoreTerm: true });
    const run = env.findMy.injectPlugin();
    await flush();
    env.clock.fire(30_000);
    await flush();
    assert.deepEqual(env.spawners[0].signals, ["SIGTERM"]);
    env.clock.fire(2000);
    await flush();
    await run;
    assert.deepEqual(
        env.spawners[0].signals,
        ["SIGTERM", "SIGKILL"],
        "only the owned child is escalated after a bounded grace period"
    );
    assert.equal(env.findMy.readiness.reason, "registration_timeout");
    assert.equal(env.clock.count(2000), 0);

    const stuck = createEnvironment({ neverStops: true });
    const stuckRun = stuck.findMy.injectPlugin();
    await flush();
    const stop = stuck.findMy.stop();
    await flush();
    stuck.clock.fire(2000);
    await flush();
    stuck.clock.fire(2000);
    await flush();
    await stop;
    assert.equal(stuck.findMy.readiness.status, "unavailable", "an unobservable exit must not hang the stop request");
    assert.equal(stuck.findMy.readiness.reason, "launch_failed");
    const retry = stuck.findMy.retry();
    await flush();
    stuck.clock.fire(2000);
    await flush();
    stuck.clock.fire(2000);
    await flush();
    await retry;
    assert.equal(stuck.spawners.length, 1, "retry must not overlap an attempt whose exit has not been observed");
    stuck.spawners[0].exit();
    await stuckRun;
};

const testPendingPermissionAndOldRegistration = async () => {
    const permissions = createEnvironment({ permissionPending: true });
    const run = permissions.findMy.injectPlugin();
    await flush();
    assert.equal(permissions.spawners.length, 0);
    permissions.clock.fire(30_000);
    await flush();
    await run;
    assert.equal(permissions.findMy.readiness.reason, "registration_timeout");
    assert.equal(permissions.findMy.injectionRunning, false, "deadline must cancel pending Automation preparation");
    assert.equal(permissions.spawners.length, 0);

    const previous = createEnvironment({ oldRegistration: true });
    const previousRun = previous.findMy.injectPlugin();
    await flush();
    assert.equal(
        previous.findMy.readiness.status,
        "initializing",
        "an old ping during teardown cannot pass a new attempt"
    );
    assert.equal(previous.clock.count(30_000), 1);
    previous.register("com.apple.findmy");
    assert.equal(previous.findMy.readiness.status, "ready");
    previous.config.open_findmy_on_startup = false;
    await previous.findMy.stop();
    await previousRun;
};

const testExplicitRestartAfterSocketLoss = async () => {
    const env = createEnvironment();
    const run = env.findMy.injectPlugin();
    await flush();
    env.register("com.apple.findmy");
    assert.equal(env.findMy.readiness.status, "ready");
    // Service restart destroys sockets before stopping the plugin; status polling
    // in that interval must not make readiness permanently unavailable.
    env.clients.delete("com.apple.findmy");
    assert.equal(env.findMy.readiness.reason, "connection_lost");
    await env.findMy.stop();
    await run;
    const restarted = env.findMy.injectPlugin();
    await flush();
    assert.equal(env.spawners.length, 2);
    assert.equal(env.findMy.readiness.status, "initializing");
    env.register("com.apple.findmy");
    assert.equal(env.findMy.readiness.status, "ready");
    env.config.open_findmy_on_startup = false;
    await env.findMy.stop();
    await restarted;
};

const testTargetedPreference = async () => {
    let enabled = true;
    let retries = 0;
    let stops = 0;
    class OtherPlugin {
        async injectPlugin() {
            throw new Error("Unrelated helper restarted");
        }
    }
    class FindMy {
        get isEnabled() {
            return enabled;
        }
        async retry() {
            retries += 1;
        }
        async stop() {
            stops += 1;
        }
    }
    const { ProcessDylibMode } = load("../src/server/api/privateApi/modes/ProcessDylibMode.ts", {
        ".": { PrivateApiMode: class {} },
        "./MacForgeMode": { MacForgeMode: {} },
        "./dylibPlugins/MessagesDylibPlugin": { MessagesDylibPlugin: OtherPlugin },
        "./dylibPlugins/FaceTimeDylibPlugin": { FaceTimeDylibPlugin: OtherPlugin },
        "./dylibPlugins/FindMyDylibPlugin": { FindMyDylibPlugin: FindMy },
        "@server/lib/logging/Loggable": { getLogger: () => ({}) }
    });
    const mode = new ProcessDylibMode();
    await mode.updateFindMyPreference();
    enabled = false;
    await mode.updateFindMyPreference();
    assert.equal(retries, 1);
    assert.equal(stops, 1);
};

const testUnavailableHttp = async () => {
    const types = load("../src/server/api/http/api/v1/responses/types.ts");
    const errors = load("../src/server/api/http/api/v1/responses/errors.ts", { "./types": types });
    const unavailable = {
        required: true,
        requested: true,
        status: "unavailable",
        reason: "registration_timeout",
        message: "Find My helper did not connect. Check system security configuration and retry."
    };
    const server = {
        repo: { getConfig: () => true },
        privateApi: {
            findMyReadiness: unavailable,
            hasClient: () => false,
            retryFindMy: async () => ({ ...unavailable, status: "initializing" })
        },
        findMyFriendsCache: { getAll: () => [{ handle: "cached" }] },
        findMyDevicesCache: { getAll: () => [{ identifier: "cached" }] }
    };
    class Success {
        constructor(ctx, response) {
            this.response = response;
        }
        send() {
            return this.response;
        }
    }
    const { FindMyRouter } = load("../src/server/api/http/api/v1/routers/findmyRouter.ts", {
        "@server/env": { isMinSequoia: true },
        "@server": { Server: () => server },
        "../responses/success": { Success },
        "../responses/errors": errors,
        "@server/api/interfaces/findMyInterface": {
            FindMyInterface: {
                refreshFriends: async () => {
                    throw new readinessModule.FindMyUnavailableError(unavailable);
                },
                refreshDevices: async () => {
                    throw new readinessModule.FindMyUnavailableError(unavailable);
                },
                getDevices: async () => server.findMyDevicesCache.getAll()
            }
        },
        "@server/events": {},
        "@server/api/privateApi/FindMyHelperReadiness": readinessModule
    });
    for (const refresh of [FindMyRouter.refreshFriends, FindMyRouter.refreshDevices]) {
        await assert.rejects(
            () => refresh({}, null),
            error => {
                assert.equal(error.status, 503);
                assert.equal(error.response.data.reason, "registration_timeout");
                return true;
            }
        );
    }
    const status = await FindMyRouter.status({}, null);
    assert.equal(status.data.status, "unavailable");
    assert.equal(status.data.helperConnected, false);
    assert.equal(status.data.cachedFriends, 1);
    assert.equal(status.data.cachedDevices, 1);
    const devices = await FindMyRouter.devices({}, null);
    assert.deepEqual(devices.data, [{ identifier: "cached" }], "unavailable helper must not block cached Devices GET");
    const retry = await FindMyRouter.retry({}, null);
    assert.equal(retry.data.status, "initializing");
};

const testStartupIpcStatus = async () => {
    const handlers = new Map();
    const server = { repo: { getConfig: () => true }, privateApi: null };
    const mocks = {
        electron: { ipcMain: { handle: (name, callback) => handlers.set(name, callback) } },
        "node-mac-permissions": {},
        "@server": { Server: () => server },
        "@server/fileSystem": {},
        "@server/api/interfaces/alertsInterface": {},
        "@server/api/apple/scripts": {},
        "@server/helpers/utils": {},
        "@server/api/interfaces/contactInterface": {},
        "../../api/privateApi/PrivateApiService": { PrivateApiService: { port: 9090 } },
        "@server/utils/PermissionUtils": {},
        "@server/api/interfaces/scheduledMessagesInterface": {},
        "@server/api/interfaces/chatInterface": {},
        "@server/api/interfaces/generalInterface": {},
        "@server/env": {},
        "@server/lib/logging/Loggable": { ...logging, getLogger: () => ({}) },
        "@server/managers/zrokManager": {},
        "@server/databases/server/constants": {}
    };
    const { IPCService } = load("../src/server/services/ipcService/index.ts", mocks);
    IPCService.startIpcListeners();
    const getStatus = handlers.get("get-private-api-status");
    const retry = handlers.get("retry-findmy-helper");

    // IPC is available during the startup delay, before initServices creates
    // PrivateApiService. Polling must not throw or claim helper readiness.
    for (const uninitialized of [null, undefined]) {
        server.privateApi = uninitialized;
        const status = await getStatus();
        assert.equal(status.enabled, true);
        assert.equal(status.connected, false);
        assert.equal(status.messagesConnected, false);
        assert.equal(status.findMy, undefined);
        await assert.rejects(
            () => retry(),
            error => error instanceof Error && /listener has not initialized yet/.test(error.message)
        );
    }

    let retries = 0;
    const readiness = { required: true, requested: true, status: "ready", reason: null, message: "Connected" };
    server.privateApi = {
        helper: {},
        hasClient: processIdentifier => processIdentifier === "com.apple.MobileSMS",
        findMyReadiness: readiness,
        retryFindMy: async () => {
            retries += 1;
            return readiness;
        }
    };
    const initialized = await getStatus();
    assert.equal(initialized.connected, true);
    assert.equal(initialized.messagesConnected, true);
    assert.equal(initialized.findMy, readiness);
    assert.equal(await retry(), readiness);
    assert.equal(retries, 1, "retry reaches the service after initialization");
};

const testRegisteredCachedFriendsRoute = async () => {
    const types = load("../src/server/api/http/api/v1/responses/types.ts");
    const errors = load("../src/server/api/http/api/v1/responses/errors.ts", { "./types": types });
    const cachedFriends = [{ handle: "cached@example.test" }];
    const server = { repo: { getConfig: () => "test-password" }, log() {} };
    const { AuthMiddleware } = load("../src/server/api/http/api/v1/middleware/authMiddleware.ts", {
        "@server": { Server: () => server },
        "@server/helpers/utils": { safeTrim: value => value.trim() },
        "../responses/errors": errors
    });
    let helperChecks = 0;
    const { PrivateApiMiddleware } = load("../src/server/api/http/api/v1/middleware/privateApiMiddleware.ts", {
        "@server/helpers/utils": {
            checkPrivateApiStatus: () => {
                helperChecks += 1;
                throw new Error("Private API is disabled or its helpers are disconnected");
            }
        },
        "../responses/errors": errors
    });
    class Success {
        constructor(ctx, response) { this.ctx = ctx; this.response = response; }
        send() { this.ctx.body = this.response.data; }
    }
    const { FindMyRouter } = load("../src/server/api/http/api/v1/routers/findmyRouter.ts", {
        "@server/env": {},
        "@server": { Server: () => server },
        "../responses/success": { Success },
        "../responses/errors": errors,
        "@server/api/interfaces/findMyInterface": { FindMyInterface: { getFriends: async () => cachedFriends } },
        "@server/events": {},
        "@server/api/privateApi/FindMyHelperReadiness": readinessModule
    });
    const passThrough = async (_ctx, next) => next();
    const mocks = {
        "@server": { Server: () => server },
        "@server/helpers/utils": { isNotEmpty: value => !!value },
        "./middleware/authMiddleware": { AuthMiddleware },
        "./middleware/privateApiMiddleware": { PrivateApiMiddleware },
        "../../types": load("../src/server/api/http/types.ts"),
        "@server/lib/logging/Loggable": { getLogger: () => ({ debug() {} }) }
    };
    for (const name of ["MetricsMiddleware", "ErrorMiddleware", "LogMiddleware"]) {
        mocks[`./middleware/${name[0].toLowerCase()}${name.slice(1)}`] = { [name]: passThrough };
    }
    const source = fs.readFileSync(path.resolve(__dirname, "../src/server/api/http/api/v1/httpRoutes.ts"), "utf8");
    for (const [, name, modulePath] of source.matchAll(/import \{ (\w+) \} from "(\.\/(?:routers|validators)\/[^\"]+)";/g)) {
        mocks[modulePath] = { [name]: new Proxy({}, { get: () => passThrough }) };
    }
    mocks["./routers/findmyRouter"] = { FindMyRouter };
    const { HttpRoutes } = load("../src/server/api/http/api/v1/httpRoutes.ts", mocks);
    const KoaRouter = require("koa-router");
    const router = new KoaRouter();
    HttpRoutes.createRoutes(router);
    const friends = ctx => router.routes()(ctx, async () => {});
    const context = password => ({
        method: "GET", path: "/api/v1/icloud/findmy/friends",
        request: { query: password == null ? {} : { password }, ip: "test" },
        req: { setTimeout() {} }, res: { setTimeout() {} }
    });
    const authenticated = context("test-password");
    await friends(authenticated);
    assert.deepEqual(authenticated.body, cachedFriends, "registered GET returns its cache without a helper");
    assert.equal(helperChecks, 0, "cached Friends GET must not consult Private API availability");
    for (const password of [undefined, "incorrect-password"]) {
        await assert.rejects(() => friends(context(password)), error => error.status === 401,
            "cached Friends GET must still require authentication");
    }
};

(async () => {
    await testLifecycle();
    await testExitBeforeRegistration();
    await testBoundedTermination();
    await testPendingPermissionAndOldRegistration();
    await testExplicitRestartAfterSocketLoss();
    await testTargetedPreference();
    await testUnavailableHttp();
    await testStartupIpcStatus();
    await testRegisteredCachedFriendsRoute();
    console.log("PASS: Find My readiness, targeted retry, timeout isolation, unavailable API and startup IPC");
})().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
