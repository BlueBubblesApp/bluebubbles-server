const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const typescript = require("typescript");

const loadTypeScriptModule = (relativeSourcePath, moduleMocks = {}) => {
    const sourcePath = path.resolve(__dirname, relativeSourcePath);
    const sourceCode = fs.readFileSync(sourcePath, "utf8");
    const compiledCode = typescript.transpileModule(sourceCode, {
        compilerOptions: {
            module: typescript.ModuleKind.CommonJS,
            target: typescript.ScriptTarget.ES2020
        },
        fileName: sourcePath
    }).outputText;

    const loadedModule = { exports: {} };
    const executeModule = new Function("require", "module", "exports", compiledCode);
    const moduleRequire = moduleName => {
        return Object.prototype.hasOwnProperty.call(moduleMocks, moduleName)
            ? moduleMocks[moduleName]
            : require(moduleName);
    };
    executeModule(moduleRequire, loadedModule, loadedModule.exports);
    return loadedModule.exports;
};

const findMyUtilities = loadTypeScriptModule("../src/server/api/lib/findmy/utils.ts");
const { normalizeFindMyFriendLocation, normalizeFindMyFriendLocations } = findMyUtilities;
const { JsonLineBuffer } = loadTypeScriptModule("../src/server/api/privateApi/JsonLineBuffer.ts");
const { selectPrivateApiClients } = loadTypeScriptModule("../src/server/api/privateApi/PrivateApiClientSelector.ts");

const normalizedLocation = normalizeFindMyFriendLocation({
    handle: " alice@example.com ",
    coordinates: ["47.61", "-122.33"],
    long_address: " Seattle, WA ",
    short_address: null,
    subtitle: "",
    title: [42, "", " Alice "],
    last_updated: "1234567",
    is_locating_in_progress: true,
    status: "live"
});

assert.equal(normalizedLocation.handle, "alice@example.com");
assert.deepEqual(normalizedLocation.coordinates, [47.61, -122.33]);
assert.equal(normalizedLocation.long_address, "Seattle, WA");
assert.equal(normalizedLocation.short_address, null);
assert.equal(normalizedLocation.subtitle, null);
assert.equal(normalizedLocation.title, "Alice");
assert.equal(normalizedLocation.last_updated, 1234567);
assert.equal(normalizedLocation.is_locating_in_progress, 1);
assert.equal(normalizedLocation.status, "live");

const missingLocation = normalizeFindMyFriendLocation({
    handle: "bob@example.com",
    coordinates: [null, ""],
    long_address: null,
    short_address: null,
    subtitle: null,
    title: null,
    last_updated: "",
    is_locating_in_progress: 0,
    status: "unexpected"
});

assert.equal(missingLocation.coordinates, null, "null or blank coordinates must not become (0, 0)");
assert.equal(missingLocation.last_updated, null);
assert.equal(missingLocation.status, "legacy");

const invalidCoordinateLocation = normalizeFindMyFriendLocation({
    ...missingLocation,
    coordinates: [91, -122.33]
});
assert.equal(invalidCoordinateLocation.coordinates, null);

const identifiedLocations = normalizeFindMyFriendLocations([
    normalizedLocation,
    { ...missingLocation, handle: null },
    missingLocation
]);
assert.deepEqual(
    identifiedLocations.map(location => location.handle),
    ["alice@example.com", "bob@example.com"]
);
assert.deepEqual(normalizeFindMyFriendLocations(null), []);

const fragmentedMessages = new JsonLineBuffer();
assert.deepEqual(fragmentedMessages.append('{"transactionId":"abc","locations":['), []);
assert.deepEqual(fragmentedMessages.append("]}\n"), ['{"transactionId":"abc","locations":[]}']);

const coalescedMessages = new JsonLineBuffer();
assert.deepEqual(coalescedMessages.append('{"event":"ping"}\n{"event":"ping"}\n'), [
    '{"event":"ping"}',
    '{"event":"ping"}'
]);

const splitDelimiterMessages = new JsonLineBuffer();
assert.deepEqual(splitDelimiterMessages.append('{"event":"first"}\n{"event":"second"}'), ['{"event":"first"}']);
assert.deepEqual(splitDelimiterMessages.append("\n"), ['{"event":"second"}']);

const utf8Message = '{"title":"Café"}\n';
const utf8MessageBytes = Buffer.from(utf8Message);
const accentedCharacterOffset = utf8MessageBytes.indexOf(Buffer.from("é"));
const splitUtf8Messages = new JsonLineBuffer();
assert.deepEqual(splitUtf8Messages.append(utf8MessageBytes.subarray(0, accentedCharacterOffset + 1)), []);
assert.deepEqual(splitUtf8Messages.append(utf8MessageBytes.subarray(accentedCharacterOffset + 1)), [
    utf8Message.trim()
]);

const messagesClient = { name: "messages", destroyed: false };
const findMyClient = { name: "findmy", destroyed: false };
const disconnectedClient = { name: "disconnected", destroyed: true };
const connectedClients = [messagesClient, findMyClient, disconnectedClient];
const clientsByProcessIdentifier = {
    "com.apple.MobileSMS": messagesClient,
    "com.apple.findmy": findMyClient,
    "com.apple.disconnected": disconnectedClient
};

assert.deepEqual(selectPrivateApiClients(connectedClients, clientsByProcessIdentifier, "com.apple.findmy"), [
    findMyClient
]);
assert.deepEqual(selectPrivateApiClients(connectedClients, clientsByProcessIdentifier, "com.apple.unknown"), []);
assert.deepEqual(selectPrivateApiClients(connectedClients, clientsByProcessIdentifier, "com.apple.disconnected"), []);
assert.deepEqual(selectPrivateApiClients(connectedClients, clientsByProcessIdentifier), [messagesClient, findMyClient]);

let activeServer;
const { FindMyInterface } = loadTypeScriptModule("../src/server/api/interfaces/findMyInterface.ts", {
    "@server": { Server: () => activeServer },
    "@server/fileSystem": { FileSystem: {} },
    "@server/env": { isMinSequoia: true },
    "@server/helpers/utils": { waitMs: async () => {} },
    "../apple/scripts": {
        quitFindMyFriends: () => "",
        startFindMyFriends: () => "",
        showFindMyFriends: () => "",
        hideFindMyFriends: () => ""
    },
    "@server/api/lib/findmy/utils": findMyUtilities
});

const createRefreshScenario = ({
    helperAvailable,
    helperResponse,
    helperError,
    fallbackError,
    initialLocations = [normalizedLocation]
}) => {
    let cachedLocations = [...initialLocations];
    const observations = {
        fallbackCalls: 0,
        helperCalls: 0,
        warnings: []
    };

    activeServer = {
        repo: {
            getConfig: name => name === "enable_private_api"
        },
        privateApi: {
            hasClient: processIdentifier => {
                assert.equal(processIdentifier, "com.apple.findmy");
                return helperAvailable;
            },
            findmy: {
                refreshFriends: async () => {
                    observations.helperCalls += 1;
                    if (helperError) throw helperError;
                    return helperResponse;
                }
            }
        },
        findMyCache: {
            getAll: () => cachedLocations,
            updateAll: locations => {
                if (locations.length > 0) cachedLocations = locations;
                return locations;
            }
        },
        logger: {
            warn: message => observations.warnings.push(message)
        }
    };

    FindMyInterface.refreshUsingFindMyApp = async () => {
        observations.fallbackCalls += 1;
        if (fallbackError) throw fallbackError;
    };

    return observations;
};

const settleBackgroundFallback = () => new Promise(resolve => setImmediate(resolve));

const runRefreshBranchTests = async () => {
    let observations = createRefreshScenario({ helperAvailable: false });
    let locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.equal(observations.helperCalls, 0);
    assert.equal(observations.fallbackCalls, 1);
    assert.equal(locations.length, 1);

    observations = createRefreshScenario({
        helperAvailable: true,
        helperResponse: {
            data: {
                locations: [],
                partial: true,
                friendListTimedOut: true,
                timedOutHandles: [],
                skippedFriends: 0
            }
        }
    });
    locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.equal(observations.helperCalls, 1);
    assert.equal(observations.fallbackCalls, 1, "an empty partial helper response must start the fallback");
    assert.equal(locations.length, 1, "an empty partial response must not erase cached friends");

    observations = createRefreshScenario({
        helperAvailable: true,
        helperResponse: {
            data: {
                locations: [normalizedLocation],
                partial: true,
                friendListTimedOut: false,
                timedOutHandles: ["bob@example.com"],
                skippedFriends: 0
            }
        }
    });
    locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.equal(observations.fallbackCalls, 0, "a partial response with usable records must not restart Find My");
    assert.equal(locations.length, 1);

    observations = createRefreshScenario({
        helperAvailable: true,
        helperResponse: {
            data: {
                locations: [],
                partial: false,
                friendListTimedOut: false,
                timedOutHandles: [],
                skippedFriends: 0
            }
        },
        initialLocations: []
    });
    locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.equal(observations.fallbackCalls, 0, "a complete empty list is a valid helper response");
    assert.deepEqual(locations, []);

    observations = createRefreshScenario({
        helperAvailable: true,
        helperError: new Error("helper failed"),
        fallbackError: new Error("fallback failed")
    });
    locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.equal(observations.helperCalls, 1);
    assert.equal(observations.fallbackCalls, 1);
    assert.equal(locations.length, 1);
    assert.equal(observations.warnings.length, 2, "helper and fallback failures must both be observed");
};

runRefreshBranchTests()
    .then(() => console.log("PASS: Find My Friends integration tests"))
    .catch(error => {
        console.error(error);
        process.exitCode = 1;
    });
