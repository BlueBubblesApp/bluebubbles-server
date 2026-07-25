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

const helpers = {
    escapeOsaExp: value => value,
    getiMessageAddressFormat: value => value,
    isEmpty: value => value == null || value.length === 0,
    isNotEmpty: value => value != null && value.length > 0
};
const scriptsPath = path.join(__dirname, "../src/server/api/apple/scripts.ts");
const scripts = loadTypeScriptModule(scriptsPath, {
    "@server/fileSystem": { FileSystem: {} },
    "@server/helpers/utils": helpers,
    "@server/env": { isMinBigSur: true, isMinVentura: true }
});

test("Tahoe any GUIDs use the service resolved from the matching chat", () => {
    const imessageScript = scripts.sendMessageFallback("any;-;test-address", "test", null, "iMessage");
    const rcsScript = scripts.sendMessageFallback("any;-;test-address", "test", null, "RCS");

    assert.match(imessageScript, /service type = iMessage/);
    assert.match(rcsScript, /service type = RCS/);
});

test("explicit service GUIDs remain authoritative", () => {
    const smsScript = scripts.sendMessageFallback("SMS;-;test-address", "test", null, "RCS");
    const rcsScript = scripts.sendMessageFallback("RCS;-;test-address", "test", null, "iMessage");

    assert.match(smsScript, /service type = SMS/);
    assert.match(rcsScript, /service type = RCS/);
});

test("unresolved any GUIDs retain the legacy iMessage fallback", () => {
    const fallbackScript = scripts.sendMessageFallback("any;-;test-address", "test", null);
    const unknownServiceScript = scripts.sendMessageFallback("any;-;test-address", "test", null, "unknown");

    assert.match(fallbackScript, /service type = iMessage/);
    assert.match(unknownServiceScript, /service type = iMessage/);
});

test("ActionHandler passes the matching chat service to the fallback script", async () => {
    const executedScripts = [];
    const chatQueries = [];
    const server = {
        iMessageRepo: {
            getChats: async options => {
                chatQueries.push(options);
                return [[{ serviceName: "RCS" }], 1];
            }
        }
    };
    const fileSystem = {
        convertMp3ToCaf: async () => undefined,
        executeAppleScript: async script => {
            executedScripts.push(script);
            if (executedScripts.length === 1) throw new Error("force fallback");
        }
    };
    const logger = {
        debug: () => undefined,
        warn: () => undefined
    };
    const actionsPath = path.join(__dirname, "../src/server/api/apple/actions.ts");
    const { ActionHandler } = loadTypeScriptModule(actionsPath, {
        "@server": { Server: () => server },
        "@server/fileSystem": { FileSystem: fileSystem },
        "@server/types": {},
        "@server/api/apple/scripts": scripts,
        "../../types": {},
        "../../helpers/utils": helpers,
        "./mappings": { tapbackUIMap: {} },
        "../interfaces/messageInterface": { MessageInterface: {} },
        "../../lib/logging/Loggable": { getLogger: () => logger }
    });

    await ActionHandler.sendMessage("any;-;test-address", "test", null);

    assert.deepEqual(chatQueries, [
        {
            chatGuid: "any;-;test-address",
            withParticipants: false,
            limit: 1
        }
    ]);
    assert.equal(executedScripts.length, 2);
    assert.match(executedScripts[1], /service type = RCS/);
});
