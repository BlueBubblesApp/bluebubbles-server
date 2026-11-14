const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const ts = require("typescript");

const load = (relative, mocks = {}, globals = {}) => {
    const filename = path.resolve(__dirname, relative);
    const source = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
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
const logging = {
    Loggable: class {
        log = { debug() {}, warn() {}, error() {} };
    }
};

const testDirectSpawner = async () => {
    const { ProcessSpawner } = load("../src/server/lib/ProcessSpawner.ts", { "./logging/Loggable": logging });
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "findmy-launcher-"));
    try {
        const executable = path.join(directory, "node executable");
        fs.symlinkSync(process.execPath, executable);
        const literalArguments = ["argument with spaces", "$(printf must-not-run)", "a; b", 'quoted"value'];
        const child = new ProcessSpawner({
            command: executable,
            args: ["-e", "process.stdout.write(JSON.stringify(process.argv.slice(1)))", ...literalArguments],
            options: { shell: false }
        });
        await child.execute();
        assert.equal(child.command, executable, "direct executable paths must not receive shell quotes");
        assert.deepEqual(JSON.parse(child.stdout), literalArguments, "direct arguments remain literal");

        const missing = new ProcessSpawner({
            command: path.join(directory, "missing executable"),
            options: { shell: false }
        });
        await assert.rejects(
            () => missing.execute(),
            error => /ENOENT/.test(error.message),
            "spawn errors must reject rather than become unhandled child errors"
        );
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
};

const testLegacySpawner = async () => {
    let captured;
    const { ProcessSpawner } = load("../src/server/lib/ProcessSpawner.ts", {
        "./logging/Loggable": logging,
        child_process: {
            spawn(command, args, options) {
                captured = { command, args, options };
                const child = new EventEmitter();
                child.stdout = new EventEmitter();
                child.stderr = new EventEmitter();
                queueMicrotask(() => child.emit("exit", 0));
                return child;
            }
        }
    });
    await new ProcessSpawner({ command: "/legacy path/tool", args: ["argument with spaces", "$VALUE"] }).execute();
    assert.equal(captured.command, '"/legacy path/tool"');
    assert.deepEqual(captured.args, ['"argument with spaces"', "$VALUE"]);
    assert.equal(captured.options.shell, true, "unrelated callers retain their existing shell behavior");
};

const testDylibEnvironment = async () => {
    const privateApi = new EventEmitter();
    const values = {
        HOME: "/test-home",
        USER: "test-user",
        PATH: "/test-bin",
        DYLD_INSERT_LIBRARIES: "/unrelated.dylib"
    };
    const before = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
    let captured;
    let plugin;
    let registrations = 0;
    try {
        Object.assign(process.env, values);
        const { DylibPlugin } = load("../src/server/api/privateApi/modes/dylibPlugins/index.ts", {
            "@server": { Server: () => ({ privateApi }) },
            "@server/helpers/utils": { waitMs: async () => {} },
            "@server/fileSystem": { FileSystem: { killProcess: async () => {}, executeAppleScript: async () => {} } },
            "@server/api/apple/scripts": { hideApp: () => "" },
            "@server/lib/logging/Loggable": logging,
            "@server/lib/ProcessSpawner": {
                ProcessSpawner: class {
                    constructor(options) {
                        captured = options;
                    }
                    async execute() {
                        privateApi.emit("client-registered", { process: "unrelated.host" });
                        privateApi.emit("client-registered", { process: "com.apple.findmy" });
                        plugin.stopRequested = true;
                    }
                }
            }
        });
        class TestPlugin extends DylibPlugin {
            parentApp = "FindMy";
            bundleIdentifier = "com.apple.findmy";
            get isEnabled() {
                return true;
            }
            get dylibPath() {
                return "/intended-helper.dylib";
            }
            get parentProcessPath() {
                return "/test/FindMy";
            }
            async afterClientRegistration() {
                registrations += 1;
            }
        }
        plugin = new TestPlugin("Test helper");
        await plugin.injectPlugin();
        assert.equal(captured.options.shell, false, "dylib hosts opt into direct execution");
        for (const key of ["HOME", "USER", "PATH"]) assert.equal(captured.options.env[key], values[key]);
        assert.equal(captured.options.env.DYLD_INSERT_LIBRARIES, "/intended-helper.dylib");
        assert.notEqual(captured.options.env, process.env);
        assert.equal(process.env.DYLD_INSERT_LIBRARIES, values.DYLD_INSERT_LIBRARIES);
        assert.equal(registrations, 1);
        assert.equal(privateApi.listenerCount("client-registered"), 0);
    } finally {
        for (const [key, value] of Object.entries(before)) {
            if (value === undefined) delete process.env[key];
            else process.env[key] = value;
        }
    }
};

const testPermissionCancellation = async () => {
    const calls = [];
    let shellCalls = 0;
    const script = 'tell application "FindMy"\nget version\nend tell';
    const mocks = {
        child_process: {
            execFile(file, args, options, callback) {
                calls.push({ file, args, options });
                if (options.signal) {
                    options.signal.addEventListener("abort", () => callback(new Error("Aborted")), { once: true });
                } else queueMicrotask(() => callback(null, "ok", ""));
            },
            exec(command, callback) {
                shellCalls += 1;
                callback(null, "ok", "");
            }
        },
        electron: { app: { setPath() {}, getPath: () => "/test-data" } },
        "electron-log": {},
        "read-chunk": {},
        "@server": { Server: () => ({ logger: { debug() {}, warn() {} } }) },
        "@server/helpers/utils": {
            isEmpty: value => !value,
            isNotEmpty: value => !!value,
            safeTrim: value => value.trim(),
            escapeDoubleQuote: value => value.replace(/"/g, '\\"')
        },
        "@server/env": {},
        "@server/databases/imessage/entity/Attachment": {},
        "../api/apple/scripts": {
            requestFindMyAutomation: () => script,
            requestSystemEventsAutomation: () => 'tell application "System Events" to get version'
        },
        "./types": {},
        "@firebase/util": {},
        "find-process": {},
        rimraf: {}
    };
    const { FileSystem } = load("../src/server/fileSystem/index.ts", mocks, { __dirname: "/test/dist" });
    const controller = new AbortController();
    const preparation = FileSystem.requestFindMyAutomationPermissions(controller.signal);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].file, "/usr/bin/osascript");
    assert.equal(calls[0].options.signal, controller.signal);
    controller.abort();
    await assert.rejects(() => preparation, /Aborted/);
    assert.equal(calls.length, 1, "cancellation must not proceed to the next permission request");
    assert.equal(shellCalls, 0, "permission preparation must not run through a shell");

    calls.length = 0;
    await FileSystem.requestFindMyAutomationPermissions();
    assert.equal(calls.length, 2);
    assert.deepEqual(calls[1].args, ["-e", script], "AppleScript text is a literal execFile argument");
    await FileSystem.executeAppleScript('tell application "Messages" to get version');
    assert.equal(shellCalls, 1, "existing non-Find-My AppleScript callers are unchanged");
};

(async () => {
    await testDirectSpawner();
    await testLegacySpawner();
    await testDylibEnvironment();
    await testPermissionCancellation();
    console.log("PASS: helper environment, direct launch, legacy shell compatibility and permission cancellation");
})().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
