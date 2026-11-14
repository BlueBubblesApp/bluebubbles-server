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

const readinessModule = loadTypeScriptModule("../src/server/api/privateApi/FindMyHelperReadiness.ts");

const findMyUtilities = loadTypeScriptModule("../src/server/api/lib/findmy/utils.ts");
const { normalizeFindMyFriendLocation, normalizeFindMyFriendLocations } = findMyUtilities;
const { JsonLineBuffer } = loadTypeScriptModule("../src/server/api/privateApi/JsonLineBuffer.ts");
const { selectPrivateApiClients } = loadTypeScriptModule("../src/server/api/privateApi/PrivateApiClientSelector.ts");
const findMyPrivateApiSupport = loadTypeScriptModule("../src/server/api/lib/findmy/privateApiSupport.ts");
const { FIND_MY_PROCESS_IDENTIFIER, MESSAGES_PROCESS_IDENTIFIER, resolveFindMyFriendsPrivateApiTarget } =
    findMyPrivateApiSupport;

const normalizedLocation = normalizeFindMyFriendLocation({
    handle: " alice@example.com ",
    coordinates: ["47.61", "-122.33"],
    long_address: " Seattle, WA ",
    short_address: null,
    subtitle: "",
    title: [42, "", " Alice "],
    last_updated: "1234567",
    is_locating_in_progress: true,
    status: "live",
    location_type: "2",
    horizontal_accuracy: "6.5",
    vertical_accuracy: 9,
    speed: "1.25",
    altitude: 32,
    description: "must not cross the API boundary"
});

assert.equal(normalizedLocation.handle, "alice@example.com");
assert.deepEqual(normalizedLocation.coordinates, [47.61, -122.33]);
assert.equal(normalizedLocation.long_address, "Seattle, WA");
assert.equal(normalizedLocation.short_address, null);
assert.equal(normalizedLocation.subtitle, null);
assert.equal(normalizedLocation.title, "Alice");
assert.equal(normalizedLocation.last_updated, 1234567);
assert.equal(normalizedLocation.is_locating_in_progress, true);
assert.equal(normalizedLocation.status, "live");
assert.equal(normalizedLocation.location_type, 2);
assert.equal(normalizedLocation.horizontal_accuracy, 6.5);
assert.equal(normalizedLocation.vertical_accuracy, 9);
assert.equal(normalizedLocation.speed, 1.25);
assert.equal(normalizedLocation.altitude, 32);
assert.equal(Object.prototype.hasOwnProperty.call(normalizedLocation, "description"), false);

// Released clients require a JSON boolean, while native helpers can send 0/1.
for (const [input, expected] of [
    [true, true], [1, true], [false, false], [0, false],
    [undefined, false], [null, false], ["1", false]
]) {
    const payload = normalizeFindMyFriendLocation({ handle: "flag@example.com", is_locating_in_progress: input });
    const serialized = JSON.parse(JSON.stringify(payload));
    assert.equal(serialized.is_locating_in_progress, expected);
    assert.equal(typeof serialized.is_locating_in_progress, "boolean");
}


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

const { FindMyFriendsCache } = loadTypeScriptModule("../src/server/api/lib/findmy/FindMyFriendsCache.ts", {
    "@server/helpers/utils": {
        isEmpty: value => value == null || (typeof value === "string" && value.trim().length === 0)
    }
});
const friendLocationCache = new FindMyFriendsCache();
friendLocationCache.updateAll([normalizedLocation, missingLocation]);
assert.equal(friendLocationCache.getAll().length, 2);
friendLocationCache.replaceAll([{ ...normalizedLocation, last_updated: 1 }]);
assert.deepEqual(friendLocationCache.getAll(), [normalizedLocation]);
friendLocationCache.replaceAll([]);
assert.deepEqual(friendLocationCache.getAll(), []);

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

assert.equal(
    resolveFindMyFriendsPrivateApiTarget({ isMinBigSur: false, isMinSonoma: false, isMinSequoia: false }),
    null
);
assert.equal(
    resolveFindMyFriendsPrivateApiTarget({ isMinBigSur: true, isMinSonoma: false, isMinSequoia: false }),
    MESSAGES_PROCESS_IDENTIFIER
);
assert.equal(resolveFindMyFriendsPrivateApiTarget({ isMinBigSur: true, isMinSonoma: true, isMinSequoia: false }), null);
assert.equal(
    resolveFindMyFriendsPrivateApiTarget({ isMinBigSur: true, isMinSonoma: true, isMinSequoia: true }),
    FIND_MY_PROCESS_IDENTIFIER
);

let activeServer;
const loadFindMyInterface = environment => {
    return loadTypeScriptModule("../src/server/api/interfaces/findMyInterface.ts", {
        "@server": { Server: () => activeServer },
        "@server/fileSystem": { FileSystem: {} },
        "@server/env": environment,
        "@server/helpers/utils": { waitMs: async () => {} },
        "../apple/scripts": {
            quitFindMyFriends: () => "",
            startFindMyFriends: () => "",
            showFindMyFriends: () => "",
            hideFindMyFriends: () => ""
        },
        "@server/api/lib/findmy/utils": findMyUtilities,
        "@server/api/lib/findmy/privateApiSupport": findMyPrivateApiSupport,
        "@server/api/privateApi/FindMyHelperReadiness": readinessModule
    }).FindMyInterface;
};

let FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: true, isMinSequoia: true });

const createRefreshScenario = ({
    helperAvailable,
    helperResponse,
    helperError,
    fallbackError,
    expectedPrivateApiTarget = FIND_MY_PROCESS_IDENTIFIER,
    initialLocations = [normalizedLocation],
    readinessStatus = helperAvailable ? "ready" : "unavailable"
}) => {
    let cachedLocations = [...initialLocations];
    const observations = {
        fallbackCalls: 0,
        helperCalls: 0,
        privateApiTargets: [],
        warnings: []
    };

    activeServer = {
        repo: {
            getConfig: name => name === "enable_private_api"
        },
        privateApi: {
            findMyReadiness: {
                required: true,
                requested: true,
                status: readinessStatus,
                reason: helperAvailable ? null : "registration_timeout",
                message: "Test helper availability"
            },
            hasClient: processIdentifier => {
                observations.privateApiTargets.push(processIdentifier);
                assert.equal(processIdentifier, expectedPrivateApiTarget);
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
            },
            replaceAll: locations => {
                cachedLocations = [...locations];
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
    assert.equal(observations.fallbackCalls, 0, "unavailable Sequoia helper must not trigger an app refresh");
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
                locations: [{ handle: null }],
                partial: false,
                friendListTimedOut: false,
                timedOutHandles: [],
                skippedFriends: 0
            }
        }
    });
    locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.equal(observations.fallbackCalls, 1, "an invalid snapshot must start the fallback");
    assert.equal(locations.length, 1, "an invalid snapshot must not erase cached friends");
    assert.equal(observations.warnings.length, 1, "an invalid snapshot must be visible in diagnostics");

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
        }
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

    observations = createRefreshScenario({ helperAvailable: false });
    await assert.rejects(() => FindMyInterface.refreshFriends(true, true), readinessModule.FindMyUnavailableError);
    assert.equal(observations.helperCalls, 0);
    assert.equal(observations.fallbackCalls, 0, "unavailable fresh refresh must not activate the app");
    assert.deepEqual(await FindMyInterface.getFriends(), [normalizedLocation], "cached GET remains available");

    observations = createRefreshScenario({ helperAvailable: true, readinessStatus: "initializing" });
    await assert.rejects(() => FindMyInterface.refreshFriends(true, true), readinessModule.FindMyUnavailableError);
    assert.equal(observations.helperCalls, 0, "a socket alone must not bypass readiness");

    observations = createRefreshScenario({ helperAvailable: true, helperError: new Error("helper failed") });
    await assert.rejects(() => FindMyInterface.refreshFriends(true, true), /usable fresh response/);
    assert.equal(observations.fallbackCalls, 0, "a failed fresh refresh must not be disguised as cached success");
    assert.deepEqual(await FindMyInterface.getFriends(), [normalizedLocation]);

    observations = createRefreshScenario({
        helperAvailable: true,
        helperResponse: {
            data: { locations: [], partial: false, friendListTimedOut: false, timedOutHandles: [], skippedFriends: 0 }
        }
    });
    assert.deepEqual(await FindMyInterface.refreshFriends(true, true), [], "complete empty snapshots are valid");
    assert.equal(observations.fallbackCalls, 0);

    FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: false, isMinSequoia: false });
    observations = createRefreshScenario({
        helperAvailable: true,
        expectedPrivateApiTarget: MESSAGES_PROCESS_IDENTIFIER,
        helperResponse: {
            data: {
                locations: [normalizedLocation],
                partial: false,
                friendListTimedOut: false,
                timedOutHandles: [],
                skippedFriends: 0
            }
        }
    });
    locations = await FindMyInterface.refreshFriends();
    await settleBackgroundFallback();
    assert.deepEqual(observations.privateApiTargets, [MESSAGES_PROCESS_IDENTIFIER]);
    assert.equal(observations.helperCalls, 1, "pre-Sequoia refreshes must continue through the Messages helper");
    assert.equal(observations.fallbackCalls, 1, "legacy refreshes must preserve the existing Find My app refresh");
    assert.equal(locations.length, 1);
};

const runFriendsSnapshotValidationTests = async () => {
    FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: true, isMinSequoia: true });
    const first = { ...normalizedLocation, handle: "first@example.test", status: "shallow", last_updated: 100 };
    const second = { ...normalizedLocation, handle: "second@example.test", status: "shallow", last_updated: 100 };
    const complete = { partial: false, friendListTimedOut: false, timedOutHandles: [], skippedFriends: 0 };
    const invalidSnapshots = [
        { ...complete, locations: [first, { handle: null }] },
        { ...complete, locations: [first, { ...first, handle: ` ${first.handle} ` }] },
        { ...complete, locations: [first, { handle: null }], partial: true },
        { ...complete, locations: [first, first], partial: true },
        { locations: [] },
        { ...complete, locations: [], partial: "false" },
        { ...complete, locations: [], friendListTimedOut: undefined },
        { ...complete, locations: [], skippedFriends: -1 },
        { ...complete, locations: [], skippedFriends: 0.5 },
        { ...complete, locations: [], timedOutHandles: null },
        { ...complete, locations: [], timedOutHandles: [""] },
        { ...complete, locations: [], friendListTimedOut: true },
        { ...complete, locations: [], timedOutHandles: [second.handle] },
        { ...complete, locations: [], skippedFriends: 1 }
    ];
    for (const response of invalidSnapshots) {
        const observations = createRefreshScenario({ helperAvailable: true, helperResponse: { data: response } });
        const cache = new FindMyFriendsCache();
        cache.replaceAll([first, second]);
        activeServer.findMyCache = cache;
        await assert.rejects(() => FindMyInterface.refreshFriends(true, true), /usable fresh response/);
        assert.deepEqual(cache.getAll(), [first, second], "validation must complete before any Friends cache mutation");
        assert.equal(observations.fallbackCalls, 0, "a rejected fresh snapshot must not become a fallback success");
    }

    const useRealCache = response => {
        createRefreshScenario({ helperAvailable: true, helperResponse: { data: response } });
        const cache = new FindMyFriendsCache();
        cache.replaceAll([first, second]);
        activeServer.findMyCache = cache;
        return cache;
    };
    let cache = useRealCache({ ...complete, locations: [] });
    assert.deepEqual(await FindMyInterface.refreshFriends(true, true), [], "a valid complete empty snapshot clears stale data");
    assert.deepEqual(cache.getAll(), []);

    cache = useRealCache({ ...complete, locations: [{ ...first, last_updated: 50 }], partial: true });
    await FindMyInterface.refreshFriends(true, true);
    assert.deepEqual(cache.getAll(), [first, second], "valid partial snapshots preserve missing friends and newer data");

    const newerFirst = { ...first, last_updated: 200 };
    cache = useRealCache({ ...complete, locations: [newerFirst], partial: true, timedOutHandles: [second.handle] });
    await FindMyInterface.refreshFriends(true, true);
    assert.deepEqual(cache.getAll(), [newerFirst, second], "a partial response preserves shallow coordinates and timestamps");

    cache = useRealCache({ ...complete, locations: [newerFirst] });
    await FindMyInterface.refreshFriends(true, true);
    assert.deepEqual(cache.getAll(), [newerFirst], "a valid complete response replaces collection membership");

    cache = useRealCache({ ...complete, locations: [], partial: true, friendListTimedOut: true });
    await assert.rejects(() => FindMyInterface.refreshFriends(true, true), /usable fresh response/);
    assert.deepEqual(cache.getAll(), [first, second], "an empty partial response retains known Friends");

    FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: false, isMinSequoia: false });
    const legacy = createRefreshScenario({
        helperAvailable: true,
        expectedPrivateApiTarget: MESSAGES_PROCESS_IDENTIFIER,
        helperResponse: { data: { locations: [first] } }
    });
    assert.equal((await FindMyInterface.refreshFriends(true, true)).length, 1,
        "older Messages helpers retain support for responses without completion metadata");
    await settleBackgroundFallback();
    assert.equal(legacy.fallbackCalls, 1);
};

runRefreshBranchTests()
    .then(runFriendsSnapshotValidationTests)
    .then(() => console.log("PASS: Find My Friends integration tests"))
    .catch(error => {
        console.error(error);
        process.exitCode = 1;
    });
