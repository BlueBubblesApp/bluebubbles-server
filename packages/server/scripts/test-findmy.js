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
assert.equal(normalizedLocation.is_locating_in_progress, 1);
assert.equal(normalizedLocation.status, "live");
assert.equal(normalizedLocation.location_type, 2);
assert.equal(normalizedLocation.horizontal_accuracy, 6.5);
assert.equal(normalizedLocation.vertical_accuracy, 9);
assert.equal(normalizedLocation.speed, 1.25);
assert.equal(normalizedLocation.altitude, 32);
assert.equal(Object.prototype.hasOwnProperty.call(normalizedLocation, "description"), false);

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
        "@server/api/lib/findmy/privateApiSupport": findMyPrivateApiSupport
    }).FindMyInterface;
};

let FindMyInterface = loadFindMyInterface({ isMinBigSur: true, isMinSonoma: true, isMinSequoia: true });

const createRefreshScenario = ({
    helperAvailable,
    helperResponse,
    helperError,
    fallbackError,
    expectedPrivateApiTarget = FIND_MY_PROCESS_IDENTIFIER,
    initialLocations = [normalizedLocation]
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
            debug: () => {},
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
    openFindMyOnStartup = true
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
        { cachedFriends: 1, cachedDevices: 1, expectedRefreshes: [] }
    ];

    for (const scenario of scenarios) {
        const refreshes = [];
        activeServer = {
            findMyFriendsCache: {
                getAll: () => Array.from({ length: scenario.cachedFriends }, () => ({}))
            },
            findMyDevicesCache: {
                getAll: () => Array.from({ length: scenario.cachedDevices }, () => ({}))
            }
        };

        const { FindMyDylibPlugin } = loadTypeScriptModule(
            "../src/server/api/privateApi/modes/dylibPlugins/FindMyDylibPlugin.ts",
            {
                "@server/env": { isMinSequoia: true },
                ".": {
                    DylibPlugin: class {
                        constructor(name) {
                            this.name = name;
                        }
                    }
                },
                "@server/fileSystem": { FileSystem: { resources: "/resources" } },
                "@server": { Server: () => activeServer },
                "@server/api/interfaces/findMyInterface": {
                    FindMyInterface: {
                        refreshFriends: async () => refreshes.push("friends"),
                        refreshDevices: async () => refreshes.push("devices")
                    }
                }
            }
        );

        const plugin = new FindMyDylibPlugin("Find My Helper");
        await plugin.afterClientRegistration();
        assert.deepEqual(refreshes, scenario.expectedRefreshes);
    }
};

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

    createDeviceRefreshScenario({
        helperAvailable: false,
        helperResponse: { data: { devices: [], partial: false, skippedDevices: 0 } }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /did not connect/);

    createDeviceRefreshScenario({
        privateApiEnabled: false,
        helperResponse: { data: { devices: [], partial: false, skippedDevices: 0 } }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /requires the Private API/);

    createDeviceRefreshScenario({
        openFindMyOnStartup: false,
        helperResponse: { data: { devices: [], partial: false, skippedDevices: 0 } }
    });
    await assert.rejects(() => FindMyInterface.refreshDevices(), /Open FindMy App on Startup/);
};

runFindMyDylibPluginTests()
    .then(runRefreshBranchTests)
    .then(runDeviceRefreshTests)
    .then(() => console.log("PASS: Find My integration tests"))
    .catch(error => {
        console.error(error);
        process.exitCode = 1;
    });
