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
    const customRequire = request =>
        Object.prototype.hasOwnProperty.call(overrides, request) ? overrides[request] : require(request);
    loadModule(loadedModule, loadedModule.exports, customRequire);
    return loadedModule.exports;
};

const zrokManagerPath = path.join(__dirname, "../src/server/managers/zrokManager/index.ts");
const token = "test-token";
const alreadyEnabledError = {
    output: "[ERROR]: unable to enable environment (you already have an enabled environment)"
};

const loadZrokManager = responses => {
    const calls = [];
    const logs = {
        debug: [],
        error: [],
        info: []
    };
    const executeCommand = async (...args) => {
        calls.push(args);
        const response = responses.shift();
        if (!response) throw new Error("Unexpected ProcessSpawner call");
        if ("error" in response) throw response.error;
        return response.output;
    };
    const logger = {
        debug: (...args) => logs.debug.push(args),
        error: (...args) => logs.error.push(args),
        info: (...args) => logs.info.push(args)
    };

    const { ZrokManager } = loadTypeScriptModule(zrokManagerPath, {
        axios: { post: async () => undefined },
        child_process: { spawn: () => undefined },
        electron: { app: { getVersion: () => "test" } },
        "@server": { Server: () => undefined },
        "@server/fileSystem": { FileSystem: { resources: "/resources" } },
        "@server/helpers/utils": {
            isEmpty: value => value == null || value.length === 0,
            isNotEmpty: value => value != null && value.length > 0
        },
        "@server/lib/logging/Loggable": {
            Loggable: class {},
            getLogger: () => logger
        },
        "@server/lib/ProcessSpawner": {
            ProcessSpawner: { executeCommand }
        }
    });

    return { calls, logs, ZrokManager };
};

const success = output => ({ output });
const failure = output => ({ error: { output } });
const expectedCall = (ZrokManager, args) => [ZrokManager.daemonPath, args, {}, "ZrokManager"];

test("returns the output when zrok enables normally", async () => {
    const { calls, ZrokManager } = loadZrokManager([success("environment enabled")]);

    assert.equal(await ZrokManager.setToken(token), "environment enabled");
    assert.deepEqual(calls, [expectedCall(ZrokManager, ["enable", token])]);
});

test("preserves invalid-token errors without disabling or retrying", async () => {
    const { calls, ZrokManager } = loadZrokManager([failure("[ERROR]: enableUnauthorized")]);

    await assert.rejects(() => ZrokManager.setToken(token), { message: "Invalid Zrok token!" });
    assert.deepEqual(calls, [expectedCall(ZrokManager, ["enable", token])]);
});

test("preserves generic enable errors without disabling or retrying", async () => {
    const { calls, ZrokManager } = loadZrokManager([failure("[ERROR]: network unavailable")]);

    await assert.rejects(() => ZrokManager.setToken(token), {
        message: "Failed to set Zrok token! Please check your server logs for more information."
    });
    assert.deepEqual(calls, [expectedCall(ZrokManager, ["enable", token])]);
});

test("disables a stale environment and retries enable exactly once", async () => {
    const { calls, ZrokManager } = loadZrokManager([
        { error: alreadyEnabledError },
        success("environment disabled"),
        success("environment enabled")
    ]);

    assert.equal(await ZrokManager.setToken(token), "environment enabled");
    assert.deepEqual(calls, [
        expectedCall(ZrokManager, ["enable", token]),
        expectedCall(ZrokManager, ["disable"]),
        expectedCall(ZrokManager, ["enable", token])
    ]);
});

test("does not retry again when the second enable fails", async () => {
    const { calls, ZrokManager } = loadZrokManager([
        { error: alreadyEnabledError },
        success("environment disabled"),
        { error: alreadyEnabledError }
    ]);

    await assert.rejects(() => ZrokManager.setToken(token), {
        message: "Failed to set Zrok token! Please check your server logs for more information."
    });
    assert.deepEqual(calls, [
        expectedCall(ZrokManager, ["enable", token]),
        expectedCall(ZrokManager, ["disable"]),
        expectedCall(ZrokManager, ["enable", token])
    ]);
});

test("preserves invalid-token errors from the retry", async () => {
    const { calls, ZrokManager } = loadZrokManager([
        { error: alreadyEnabledError },
        success("environment disabled"),
        failure("[ERROR]: enableUnauthorized")
    ]);

    await assert.rejects(() => ZrokManager.setToken(token), { message: "Invalid Zrok token!" });
    assert.deepEqual(calls, [
        expectedCall(ZrokManager, ["enable", token]),
        expectedCall(ZrokManager, ["disable"]),
        expectedCall(ZrokManager, ["enable", token])
    ]);
});
