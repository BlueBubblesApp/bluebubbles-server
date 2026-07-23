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

const constantsPath = path.join(__dirname, "../src/server/databases/imessage/pollers/constants.ts");
const constants = loadTypeScriptModule(constantsPath);

const eventCachePath = path.join(__dirname, "../src/server/eventCache/index.ts");
const { EventCache } = loadTypeScriptModule(eventCachePath, {
    "@server/helpers/utils": {
        isEmpty: value => value === null || value === undefined || value.length === 0
    }
});

const pollerPath = path.join(__dirname, "../src/server/databases/imessage/pollers/index.ts");
const { IMessageCache, IMessagePoller } = loadTypeScriptModule(pollerPath, {
    "@server/eventCache": { EventCache },
    "@server/events": { CHAT_READ_STATUS_CHANGED: "chat-read-status-changed" },
    "@server/lib/logging/Loggable": { Loggable: class {} },
    "./constants": constants
});

const makeMessage = guid => ({
    guid,
    dateCreated: new Date(1_000),
    isDelivered: false,
    dateDelivered: null,
    dateRead: null,
    dateEdited: null,
    dateRetracted: null,
    didNotifyRecipient: true,
    hasUnsentParts: false
});

const makeMessageState = cacheTime => ({
    cacheTime,
    dateCreated: 1_000,
    isDelivered: false,
    dateDelivered: 0,
    dateRead: 0,
    dateEdited: 0,
    dateRetracted: 0,
    didNotifyRecipient: true,
    hasUnsentParts: false
});

test("a reconciled message stays deduplicated for the full lookback", () => {
    const cache = new IMessageCache();
    const poller = new IMessagePoller({}, cache);
    const guid = "reconciled-message";
    const reconciledAt = Date.now() - constants.MESSAGE_RECONCILE_LOOKBACK_MS;

    cache.messageEvents.items.push({ date: reconciledAt, item: guid });
    cache.messageStates[guid] = makeMessageState(reconciledAt);

    cache.trimCaches();

    assert.equal(cache.messageEvents.find(guid), guid);
    assert.equal(poller.processMessageEvent(makeMessage(guid)), null);
});

test("expired message entries are still pruned", () => {
    const cache = new IMessageCache();
    const guid = "expired-message";
    const expiredAt = Date.now() - constants.MESSAGE_DEDUP_CACHE_RETENTION_MS - 1;

    cache.messageEvents.items.push({ date: expiredAt, item: guid });
    cache.messageStates[guid] = makeMessageState(expiredAt);

    cache.trimCaches();

    assert.equal(cache.messageEvents.find(guid), null);
    assert.equal(cache.messageStates[guid], undefined);
});

test("chat deduplication keeps its shorter retention", () => {
    const cache = new IMessageCache();
    const guid = "expired-chat";
    const expiredAt = Date.now() - constants.CHAT_DEDUP_CACHE_RETENTION_MS - 1;

    cache.chatEvents.items.push({ date: expiredAt, item: guid });
    cache.chatStates[guid] = {
        cacheTime: expiredAt,
        lastReadMessageTimestamp: 1_000
    };

    cache.trimCaches();

    assert.equal(cache.chatEvents.find(guid), null);
    assert.equal(cache.chatStates[guid], undefined);
});
