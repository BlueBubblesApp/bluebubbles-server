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
const { normalizeFindMyDevice, normalizeFindMyDevices, normalizeFindMyFriendLocation, normalizeFindMyFriendLocations } =
    findMyUtilities;
const { JsonLineBuffer } = loadTypeScriptModule("../src/server/api/privateApi/JsonLineBuffer.ts");
const { selectPrivateApiClients } = loadTypeScriptModule("../src/server/api/privateApi/PrivateApiClientSelector.ts");
const findMyPrivateApiSupport = loadTypeScriptModule("../src/server/api/lib/findmy/privateApiSupport.ts");
const {
    FIND_MY_PROCESS_IDENTIFIER,
    MESSAGES_PROCESS_IDENTIFIER,
    resolveFindMyDevicesPrivateApiTarget,
    resolveFindMyFriendsPrivateApiTarget
} = findMyPrivateApiSupport;

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

const rawDeviceWithLocation = {
    identifier: " device-1 ",
    name: " Example Mac ",
    displayName: " MacBook Pro ",
    model: "Mac14,6",
    rawDeviceModel: "Mac14,6-silver",
    systemVersion: "15.7.7",
    batteryLevel: "0.75",
    batteryStatus: "charging",
    deviceConnectedState: "online",
    discoveryIdentifier: "00000000-0000-4000-8000-000000000001",
    category: "MacBookPro",
    address: {
        label: " Seattle, WA ",
        countryCode: "US",
        administrativeArea: "WA",
        locality: "Seattle",
        mapItemFullAddress: "Seattle, WA",
        formattedAddressLines: ["Seattle, WA", ""]
    },
    location: {
        latitude: "47.61",
        longitude: "-122.33",
        horizontalAccuracy: "6.5",
        verticalAccuracy: 9,
        altitude: 32,
        timeStamp: "1234567",
        floorLevel: 4,
        isInaccurate: false,
        isOld: false,
        locationFinished: true,
        positionType: "current"
    },
    description: "must not cross the API boundary"
};
const normalizedDeviceWithLocation = normalizeFindMyDevice(rawDeviceWithLocation);
assert.equal(normalizedDeviceWithLocation.identifier, "device-1");
assert.equal(normalizedDeviceWithLocation.name, "Example Mac");
assert.equal(normalizedDeviceWithLocation.systemVersion, "15.7.7");
assert.equal(normalizedDeviceWithLocation.batteryLevel, 0.75);
assert.equal(normalizedDeviceWithLocation.batteryStatus, "charging");
assert.equal(normalizedDeviceWithLocation.deviceStatus, "online");
assert.equal(normalizedDeviceWithLocation.location.latitude, 47.61);
assert.equal(normalizedDeviceWithLocation.location.longitude, -122.33);
assert.equal(normalizedDeviceWithLocation.location.timeStamp, 1234567);
assert.deepEqual(normalizedDeviceWithLocation.address.formattedAddressLines, ["Seattle, WA"]);
assert.equal(
    normalizedDeviceWithLocation.crowdSourcedLocation,
    undefined,
    "a direct location must not be relabeled as crowd-sourced"
);
assert.equal(Object.prototype.hasOwnProperty.call(normalizedDeviceWithLocation, "description"), false);

const normalizedOfflineDevice = normalizeFindMyDevice({
    identifier: "offline-device",
    batteryLevel: 0,
    location: null
});
assert.equal(normalizedOfflineDevice.batteryLevel, 0);
assert.equal(normalizedOfflineDevice.location, undefined, "an offline device must not gain zero coordinates");
assert.equal(
    normalizeFindMyDevice({ identifier: "", discoveryIdentifier: "fallback" }),
    null,
    "the server contract requires the helper's selected stable identifier"
);
assert.equal(
    normalizeFindMyDevice({ identifier: "invalid", location: { latitude: 91, longitude: 1 } }).location,
    undefined
);
assert.equal(normalizeFindMyDevice({ identifier: "invalid", batteryLevel: true }).batteryLevel, undefined);
assert.equal(
    normalizeFindMyDevice({ identifier: "invalid", location: { latitude: [], longitude: false } }).location,
    undefined
);
assert.deepEqual(normalizeFindMyDevices(null), []);

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

const { FindMyDevicesCache } = loadTypeScriptModule("../src/server/api/lib/findmy/FindMyDevicesCache.ts");
const deviceCache = new FindMyDevicesCache();
deviceCache.updateAll([normalizedDeviceWithLocation]);
assert.deepEqual(deviceCache.getAll(), [normalizedDeviceWithLocation]);
deviceCache.updateAll([normalizedOfflineDevice]);
assert.equal(deviceCache.getAll().length, 2);
deviceCache.replaceAll([normalizedOfflineDevice]);
assert.deepEqual(deviceCache.getAll(), [normalizedOfflineDevice]);
deviceCache.replaceAll([]);
assert.deepEqual(deviceCache.getAll(), []);

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
assert.equal(resolveFindMyDevicesPrivateApiTarget({ isMinSequoia: false }), null);
assert.equal(resolveFindMyDevicesPrivateApiTarget({ isMinSequoia: true }), FIND_MY_PROCESS_IDENTIFIER);

let activeServer;
let openedFindMyCommands = [];
const loadFindMyInterface = environment => {
    return loadTypeScriptModule("../src/server/api/interfaces/findMyInterface.ts", {
        "@server": { Server: () => activeServer },
        "@server/fileSystem": {
            FileSystem: {
                execShellCommand: async command => openedFindMyCommands.push(command)
            }
        },
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
        findMyFriendsCache: {
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

const createDeviceRefreshScenario = ({
    helperAvailable = true,
    helperResponse,
    initialDevices = [],
    privateApiEnabled = true,
    openFindMyOnStartup = true,
    readinessStatus = !privateApiEnabled || !openFindMyOnStartup
        ? "disabled"
        : helperAvailable
        ? "ready"
        : "unavailable"
}) => {
    let cachedDevices = [...initialDevices];
    openedFindMyCommands = [];
    const observations = {
        helperCalls: 0,
        privateApiTargets: [],
        replacements: 0,
        updates: 0,
        warnings: []
    };

    activeServer = {
        repo: {
            getConfig: name => {
                if (name === "enable_private_api") return privateApiEnabled;
                if (name === "open_findmy_on_startup") return openFindMyOnStartup;
                return null;
            }
        },
        privateApi: {
            findMyReadiness: {
                required: true,
                requested: privateApiEnabled && openFindMyOnStartup,
                status: readinessStatus,
                reason: readinessStatus === "unavailable" ? "registration_timeout" : null,
                message: "Test helper availability"
            },
            hasClient: processIdentifier => {
                observations.privateApiTargets.push(processIdentifier);
                assert.equal(processIdentifier, FIND_MY_PROCESS_IDENTIFIER);
                return helperAvailable;
            },
            findmy: {
                refreshDevices: async () => {
                    observations.helperCalls += 1;
                    return helperResponse;
                }
            }
        },
        findMyDevicesCache: {
            getAll: () => [...cachedDevices],
            updateAll: devices => {
                observations.updates += 1;
                const devicesByIdentifier = new Map(
                    cachedDevices.map(device => [device.identifier ?? device.id, device])
                );
                for (const device of devices) {
                    devicesByIdentifier.set(device.identifier ?? device.id, device);
                }
                cachedDevices = Array.from(devicesByIdentifier.values());
                return devices;
            },
            replaceAll: devices => {
                observations.replacements += 1;
                cachedDevices = [...devices];
                return devices;
            }
        },
        logger: {
            debug: () => {},
            warn: message => observations.warnings.push(message)
        }
    };

    return observations;
};

const runFindMyDylibPluginTests = async () => {
    const scenarios = [
        { cachedFriends: 0, cachedDevices: 0, expectedRefreshes: ["friends", "devices"] },
        { cachedFriends: 1, cachedDevices: 0, expectedRefreshes: ["devices"] },
        { cachedFriends: 0, cachedDevices: 1, expectedRefreshes: ["friends"] },
        { cachedFriends: 1, cachedDevices: 1, expectedRefreshes: [] },
        { cachedFriends: 0, cachedDevices: 0, expectedRefreshes: ["friends", "devices"], fail: "friends" },
        { cachedFriends: 0, cachedDevices: 0, expectedRefreshes: ["friends", "devices"], fail: "devices" }
    ];

    for (const scenario of scenarios) {
        const refreshes = [];
        const warnings = [];
        activeServer = {
            repo: { getConfig: () => true },
            privateApi: { hasClient: () => true },
            findMyFriendsCache: {
                getAll: () => Array.from({ length: scenario.cachedFriends }, () => ({}))
            },
            findMyDevicesCache: {
                getAll: () => Array.from({ length: scenario.cachedDevices }, () => ({}))
            }
        };
        const refresh = async name => {
            refreshes.push(name);
            if (scenario.fail === name) throw new Error("Test refresh failed");
        };
        const { FindMyDylibPlugin } = loadTypeScriptModule(
            "../src/server/api/privateApi/modes/dylibPlugins/FindMyDylibPlugin.ts",
            {
                "@server/env": { isMinSequoia: true },
                ".": {
                    DylibPlugin: class {
                        constructor(name) {
                            this.name = name;
                            this.log = { warn: message => warnings.push(message) };
                        }
                    }
                },
                "@server/fileSystem": { FileSystem: { resources: "/resources" } },
                "@server": { Server: () => activeServer },
                "@server/api/interfaces/findMyInterface": {
                    FindMyInterface: {
                        refreshFriends: async () => refresh("friends"),
                        refreshDevices: async () => refresh("devices")
                    }
                },
                "@server/api/privateApi/FindMyHelperReadiness": readinessModule
            }
        );

        const plugin = new FindMyDylibPlugin("Find My Helper");
        await plugin.afterClientRegistration();
        assert.deepEqual(refreshes, [], "unaccepted registrations cannot warm either cache");
        plugin.acceptRegistration = true;
        await plugin.afterClientRegistration();
        assert.deepEqual(refreshes, scenario.expectedRefreshes);
        assert.equal(plugin.readiness.status, "ready");
        assert.equal(
            warnings.length,
            scenario.fail ? 1 : 0,
            "a failed warmup must be logged while allowing the other cache to initialize"
        );
    }
};

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
        activeServer.findMyFriendsCache = cache;
        await assert.rejects(() => FindMyInterface.refreshFriends(true, true), /usable fresh response/);
        assert.deepEqual(cache.getAll(), [first, second], "validation must complete before any Friends cache mutation");
        assert.equal(observations.fallbackCalls, 0, "a rejected fresh snapshot must not become a fallback success");
    }

    const useRealCache = response => {
        createRefreshScenario({ helperAvailable: true, helperResponse: { data: response } });
        const cache = new FindMyFriendsCache();
        cache.replaceAll([first, second]);
        activeServer.findMyFriendsCache = cache;
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

const runDeviceRefreshTests = async () => {
    FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: true, isMinSequoia: true });

    let observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: { data: { devices: [], partial: false, skippedDevices: 0 } }
    });
    let devices = await FindMyInterface.getDevices();
    assert.deepEqual(devices, [normalizedOfflineDevice]);
    assert.deepEqual(openedFindMyCommands, [], "GET Devices must not activate or switch the Find My app");
    assert.equal(observations.helperCalls, 0);

    observations = createDeviceRefreshScenario({
        helperResponse: {
            data: {
                devices: [rawDeviceWithLocation, { identifier: "offline-device", batteryLevel: 0 }],
                partial: false,
                skippedDevices: 0
            }
        }
    });
    devices = await FindMyInterface.refreshDevices();
    assert.deepEqual(openedFindMyCommands, ["/usr/bin/open findmy://devices"]);
    assert.equal(observations.helperCalls, 1);
    assert.equal(observations.replacements, 1);
    assert.equal(observations.updates, 0);
    assert.equal(devices.length, 2);
    assert.equal(devices.filter(device => device.location != null).length, 1);

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: {
            data: {
                devices: [rawDeviceWithLocation],
                partial: true,
                skippedDevices: 1
            }
        }
    });
    devices = await FindMyInterface.refreshDevices();
    assert.equal(observations.updates, 1);
    assert.equal(observations.replacements, 0, "a partial snapshot must not remove cached devices");
    assert.equal(observations.warnings.length, 1);
    assert.equal(devices.length, 2);

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: { data: { devices: [], partial: false, skippedDevices: 0 } }
    });
    devices = await FindMyInterface.refreshDevices();
    assert.equal(observations.replacements, 1);
    assert.deepEqual(devices, [], "a complete empty snapshot must clear stale devices");

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: {
            data: {
                devices: [{ identifier: "" }],
                partial: false,
                skippedDevices: 0
            }
        }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /invalid device records/);
    assert.equal(observations.replacements, 0, "an invalid snapshot must preserve the device cache");

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: {
            data: {
                devices: [rawDeviceWithLocation, { identifier: "" }],
                partial: false,
                skippedDevices: 0
            }
        }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /invalid device records/);
    assert.equal(observations.replacements, 0, "a mixed invalid snapshot must preserve the device cache");

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: {
            data: {
                devices: [rawDeviceWithLocation, rawDeviceWithLocation],
                partial: false,
                skippedDevices: 0
            }
        }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /duplicate device identifiers/);
    assert.equal(observations.replacements, 0, "a duplicate snapshot must preserve the device cache");

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: { data: { devices: [], skippedDevices: 0 } }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /invalid completion state/);
    assert.equal(observations.replacements, 0, "an incomplete response contract must preserve the device cache");

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: { data: { devices: [], partial: false, skippedDevices: null } }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /invalid skipped-device count/);
    assert.equal(observations.replacements, 0, "an invalid skipped count must preserve the device cache");

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: { data: { devices: [], partial: false, skippedDevices: 1 } }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /inconsistent completion state/);
    assert.equal(observations.replacements, 0, "an inconsistent partial state must preserve the device cache");

    for (const scenario of [
        { helperAvailable: false },
        { helperAvailable: true, readinessStatus: "initializing" },
        { helperAvailable: true, readinessStatus: "unavailable" },
        { helperAvailable: false, readinessStatus: "ready" },
        { privateApiEnabled: false },
        { openFindMyOnStartup: false }
    ]) {
        observations = createDeviceRefreshScenario({
            ...scenario,
            initialDevices: [normalizedOfflineDevice],
            helperResponse: { data: { devices: [], partial: false, skippedDevices: 0 } }
        });
        await assert.rejects(() => FindMyInterface.refreshDevices(), readinessModule.FindMyUnavailableError);
        assert.deepEqual(openedFindMyCommands, [], "unavailable readiness must block the Devices URI");
        assert.equal(observations.helperCalls, 0);
        assert.equal(observations.replacements, 0);
        assert.equal(observations.updates, 0);
        assert.deepEqual(
            await FindMyInterface.getDevices(),
            [normalizedOfflineDevice],
            "cached Devices GET remains available for every unavailable state"
        );
    }

    // Snapshot validation must finish before either cache mutation path.
    for (const partial of [false, true]) {
        for (const devices of [
            [rawDeviceWithLocation, { identifier: "" }],
            [rawDeviceWithLocation, { identifier: rawDeviceWithLocation.identifier.trim() }]
        ]) {
            observations = createDeviceRefreshScenario({
                initialDevices: [normalizedOfflineDevice],
                helperResponse: { data: { devices, partial, skippedDevices: partial ? 1 : 0 } }
            });
            await assert.rejects(() => FindMyInterface.refreshDevices(), /invalid device records|duplicate device/);
            assert.equal(observations.replacements, 0);
            assert.equal(observations.updates, 0, "invalid partial snapshots must not mutate the cache either");
            assert.deepEqual(await FindMyInterface.getDevices(), [normalizedOfflineDevice]);
        }
    }

    observations = createDeviceRefreshScenario({
        initialDevices: [normalizedOfflineDevice],
        helperResponse: { data: { devices: [], partial: true, skippedDevices: 1 } }
    });
    assert.deepEqual(
        await FindMyInterface.refreshDevices(),
        [normalizedOfflineDevice],
        "a valid empty partial result must retain known devices"
    );
    assert.equal(observations.updates, 1);
    assert.equal(observations.replacements, 0);

    FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: false, isMinSequoia: false });
    observations = createDeviceRefreshScenario({ helperAvailable: false });
    let legacyAppRefreshes = 0;
    const filesRead = [];
    FindMyInterface.refreshUsingFindMyApp = async () => {
        legacyAppRefreshes += 1;
    };
    FindMyInterface.readDataFile = async type => {
        filesRead.push(type);
        return type === "Devices" ? [normalizedOfflineDevice] : [];
    };
    assert.deepEqual(await FindMyInterface.refreshDevices(), [normalizedOfflineDevice]);
    assert.equal(legacyAppRefreshes, 1, "earlier macOS retains the existing app refresh");
    assert.deepEqual(filesRead, ["Devices", "Items"], "earlier macOS retains data-file routing");
    assert.equal(observations.helperCalls, 0);
    assert.deepEqual(openedFindMyCommands, [], "earlier macOS does not use the new Devices URI/helper path");
};

runFindMyDylibPluginTests()
    .then(runRefreshBranchTests)
    .then(runDeviceRefreshTests)
    .then(runFriendsSnapshotValidationTests)
    .then(() => console.log("PASS: Find My integration tests"))
    .catch(error => {
        console.error(error);
        process.exitCode = 1;
    });
