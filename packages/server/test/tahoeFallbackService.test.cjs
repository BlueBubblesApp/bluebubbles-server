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
const actionsPath = path.join(__dirname, "../src/server/api/apple/actions.ts");
const loadActionHandler = ({ server, fileSystem, logger }) =>
    loadTypeScriptModule(actionsPath, {
        "@server": { Server: () => server },
        "@server/fileSystem": { FileSystem: fileSystem },
        "@server/types": {},
        "@server/api/apple/scripts": scripts,
        "../../types": {},
        "../../helpers/utils": helpers,
        "./mappings": { tapbackUIMap: {} },
        "../interfaces/messageInterface": { MessageInterface: {} },
        "../../lib/logging/Loggable": { getLogger: () => logger }
    }).ActionHandler;
const resolutionError =
    "Unable to resolve a supported Messages service for this chat; the fallback message was not sent.";

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
    assert.throws(() => scripts.sendMessageFallback("any;-;test-address", "test", null), {
        message: resolutionError
    });
    assert.throws(() => scripts.sendMessageFallback("any;-;test-address", "test", null, "unknown"), {
        message: resolutionError
    });
});

test("ActionHandler passes every supported service resolved from a Tahoe any chat", async () => {
    const executedScripts = [];
    const chatQueries = [];
    let resolvedService;
    const server = {
        iMessageRepo: {
            getChats: async options => {
                chatQueries.push(options);
                return [[{ serviceName: resolvedService }], 1];
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
        debug: () => undefined,
        warn: () => undefined
    };
    const ActionHandler = loadActionHandler({ server, fileSystem, logger });
    const supportedServices = ["iMessage", "SMS", "RCS"];

    for (const service of supportedServices) {
        resolvedService = service;
        await ActionHandler.sendMessage("any;-;test-address", "test", null);
        assert.match(executedScripts.at(-1), new RegExp(`service type = ${service}`));
    }

    assert.deepEqual(
        chatQueries,
        supportedServices.map(() => ({
            chatGuid: "any;-;test-address",
            withParticipants: false,
            limit: 1
        }))
    );
    assert.equal(executedScripts.length, supportedServices.length * 2);
    assert.equal(
        executedScripts.filter(script => script.includes("set targetBuddy to")).length,
        supportedServices.length
    );
});

test("ActionHandler does not query chat metadata for explicit service GUIDs", async () => {
    const executedScripts = [];
    let chatQueries = 0;
    const server = {
        iMessageRepo: {
            getChats: async () => {
                chatQueries += 1;
                return [[{ serviceName: "iMessage" }], 1];
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
        debug: () => undefined,
        warn: () => undefined
    };
    const ActionHandler = loadActionHandler({ server, fileSystem, logger });

    for (const service of ["iMessage", "SMS", "RCS"]) {
        await ActionHandler.sendMessage(`${service};-;test-address`, "test", null);
        assert.match(executedScripts.at(-1), new RegExp(`service type = ${service}`));
    }

    assert.equal(chatQueries, 0);
});

test("ActionHandler fails closed without executing fallback when lookup cannot resolve a service", async () => {
    const executedScripts = [];
    const debugMessages = [];
    const warnMessages = [];
    const server = {
        iMessageRepo: {
            getChats: async () => {
                throw new Error("private-database-details");
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
        warn: message => warnMessages.push(message)
    };
    const ActionHandler = loadActionHandler({ server, fileSystem, logger });
    const resolutionFailures = [
        async () => {
            throw new Error("private-database-details");
        },
        async () => [[], 0],
        async () => [[{ serviceName: null }], 1],
        async () => [[{ serviceName: "unknown" }], 1]
    ];

    for (const getChats of resolutionFailures) {
        server.iMessageRepo.getChats = getChats;
        await assert.rejects(() => ActionHandler.sendMessage("any;-;test-address", "test", null), {
            message: resolutionError
        });
    }

    assert.equal(executedScripts.length, resolutionFailures.length);
    assert.equal(
        executedScripts.every(script => script.includes("set targetChat to")),
        true
    );
    assert.equal(
        debugMessages.some(message => message.includes("private-database-details")),
        false
    );
    assert.deepEqual(
        warnMessages,
        resolutionFailures.map(() => resolutionError)
    );
    assert.equal(
        debugMessages.includes("Failed to resolve the fallback chat service; the fallback message will not be sent."),
        true
    );
});
