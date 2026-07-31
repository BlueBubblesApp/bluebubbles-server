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
    const smsScript = scripts.sendMessageFallback("any;-;test-address", "test", null, "SMS");
    const rcsScript = scripts.sendMessageFallback("any;-;test-address", "test", null, "RCS");

    assert.match(imessageScript, /service type = iMessage/);
    assert.match(smsScript, /service type = SMS/);
    assert.match(rcsScript, /service type = RCS/);
});

test("explicit service GUIDs and unqualified addresses preserve their existing behavior", () => {
    const imessageScript = scripts.sendMessageFallback("iMessage;-;test-address", "test", null, "SMS");
    const smsScript = scripts.sendMessageFallback("SMS;-;test-address", "test", null, "RCS");
    const rcsScript = scripts.sendMessageFallback("RCS;-;test-address", "test", null, "iMessage");
    const unqualifiedScript = scripts.sendMessageFallback("test-address", "test", null);

    assert.match(imessageScript, /service type = iMessage/);
    assert.match(smsScript, /service type = SMS/);
    assert.match(rcsScript, /service type = RCS/);
    assert.match(unqualifiedScript, /service type = iMessage/);
});

test("unresolved or unsupported any GUID services fail closed", () => {
    const expectedError =
        /Unable to resolve a supported Messages service for this chat; the fallback message was not sent/;

    assert.throws(() => scripts.sendMessageFallback("any;-;test-address", "test", null), expectedError);
    assert.throws(() => scripts.sendMessageFallback("any;-;test-address", "test", null, "unknown"), expectedError);
});

test("ActionHandler passes the matching service and fails closed when lookup cannot resolve it", async () => {
    const executedScripts = [];
    const chatQueries = [];
    const debugMessages = [];
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
            if (script.includes("set targetChat to")) throw new Error("force fallback");
        }
    };
    const logger = {
        debug: message => debugMessages.push(message),
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

    server.iMessageRepo.getChats = async () => {
        throw new Error("private-database-details");
    };
    await assert.rejects(
        () => ActionHandler.sendMessage("any;-;test-address", "test", null),
        /Unable to resolve a supported Messages service for this chat; the fallback message was not sent/
    );

    assert.equal(executedScripts.length, 3);
    assert.equal(
        debugMessages.some(message => message.includes("private-database-details")),
        false
    );
    assert.equal(
        debugMessages.includes("Failed to resolve the fallback chat service; the fallback message will not be sent."),
        true
    );

    server.iMessageRepo.getChats = async () => [[], 0];
    await assert.rejects(
        () => ActionHandler.sendMessage("any;-;test-address", "test", null),
        /Unable to resolve a supported Messages service for this chat; the fallback message was not sent/
    );
    assert.equal(executedScripts.length, 4);

    server.iMessageRepo.getChats = async () => [[{ serviceName: "unknown" }], 1];
    await assert.rejects(
        () => ActionHandler.sendMessage("any;-;test-address", "test", null),
        /Unable to resolve a supported Messages service for this chat; the fallback message was not sent/
    );
    assert.equal(executedScripts.length, 5);
});
