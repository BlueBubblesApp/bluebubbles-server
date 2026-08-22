import type { FindMyItem, FindMyDevice, FindMyFriendLocation } from "@server/api/lib/findmy/types";

const FIND_MY_FRIEND_STATUSES = ["legacy", "live", "shallow"] as const;

const isFindMyFriendStatus = (value: unknown): value is FindMyFriendLocation["status"] => {
    return FIND_MY_FRIEND_STATUSES.some(status => status === value);
};

const normalizeOptionalString = (value: unknown): string | null => {
    if (typeof value !== "string") return null;
    const trimmedValue = value.trim();
    return trimmedValue.length > 0 ? trimmedValue : null;
};

const normalizeOptionalNumber = (value: unknown): number | null => {
    if (typeof value !== "number" && typeof value !== "string") return null;
    if (typeof value === "string" && value.trim().length === 0) return null;

    const numericValue = Number(value);
    return Number.isFinite(numericValue) ? numericValue : null;
};

const normalizeOptionalBoolean = (value: unknown): boolean | undefined => {
    return typeof value === "boolean" ? value : undefined;
};

const objectValue = (value: unknown): Record<string, unknown> | null => {
    return value != null && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : null;
};

const normalizeCoordinatePair = (value: unknown): [number, number] | null => {
    if (!Array.isArray(value)) return null;

    const latitude = normalizeOptionalNumber(value[0]);
    const longitude = normalizeOptionalNumber(value[1]);
    if (latitude == null || longitude == null) return null;
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return null;
    return [latitude, longitude];
};

const normalizeLocationTitle = (value: unknown): string | null => {
    if (!Array.isArray(value)) return normalizeOptionalString(value);
    return value.map(normalizeOptionalString).find(candidate => candidate != null) ?? null;
};

export const getFindMyItemModelDisplayName = (item: FindMyItem): string => {
    if (item?.productType?.type === "b389") return "AirTag";

    return item?.productType?.productInformation?.modelName ?? item?.productType?.type ?? "Unknown";
};

export const transformFindMyItemToDevice = (item: FindMyItem): FindMyDevice => ({
    deviceModel: item?.productType?.type,
    id: item?.identifier,
    batteryStatus: "Unknown",
    audioChannels: [],
    lostModeCapable: true,
    batteryLevel: item?.batteryStatus,
    locationEnabled: true,
    isConsideredAccessory: true,
    address: item?.address,
    location: item?.location,
    modelDisplayName: getFindMyItemModelDisplayName(item),
    fmlyShare: false,
    thisDevice: false,
    lostModeEnabled: Boolean(item?.lostModeMetadata ?? false),
    deviceDisplayName: item?.role?.emoji,
    safeLocations: item?.safeLocations,
    name: item?.name,
    isMac: false,
    rawDeviceModel: item?.productType?.type,
    prsId: "owner",
    locationCapable: true,
    deviceClass: item?.productType?.type,
    crowdSourcedLocation: item?.crowdSourcedLocation,

    identifier: item?.identifier,
    productIdentifier: item?.productIdentifier,
    role: item?.role,
    serialNumber: item?.serialNumber,
    lostModeMetadata: item?.lostModeMetadata,
    groupIdentifier: item?.groupIdentifier,
    groupName: item.groupName,
    isAppleAudioAccessory: item?.isAppleAudioAccessory,
    capabilities: item?.capabilities
});

export const normalizeFindMyFriendLocation = (location: unknown): FindMyFriendLocation => {
    const untrustedLocation =
        location != null && typeof location === "object" && !Array.isArray(location)
            ? (location as Record<string, unknown>)
            : {};
    const untrustedStatus = untrustedLocation.status;
    const status = isFindMyFriendStatus(untrustedStatus) ? untrustedStatus : "legacy";

    return {
        handle: normalizeOptionalString(untrustedLocation.handle),
        coordinates: normalizeCoordinatePair(untrustedLocation.coordinates),
        long_address: normalizeOptionalString(untrustedLocation.long_address),
        short_address: normalizeOptionalString(untrustedLocation.short_address),
        subtitle: normalizeOptionalString(untrustedLocation.subtitle),
        title: normalizeLocationTitle(untrustedLocation.title),
        last_updated: normalizeOptionalNumber(untrustedLocation.last_updated),
        is_locating_in_progress:
            untrustedLocation.is_locating_in_progress === true || untrustedLocation.is_locating_in_progress === 1
                ? 1
                : 0,
        status,
        location_type: normalizeOptionalNumber(untrustedLocation.location_type),
        horizontal_accuracy: normalizeOptionalNumber(untrustedLocation.horizontal_accuracy),
        vertical_accuracy: normalizeOptionalNumber(untrustedLocation.vertical_accuracy),
        speed: normalizeOptionalNumber(untrustedLocation.speed),
        altitude: normalizeOptionalNumber(untrustedLocation.altitude)
    };
};

export const normalizeFindMyFriendLocations = (locations: unknown): FindMyFriendLocation[] => {
    if (!Array.isArray(locations)) return [];
    return locations.map(normalizeFindMyFriendLocation).filter(location => location.handle != null);
};

const normalizeFindMyDeviceLocation = (value: unknown): FindMyDevice["location"] | undefined => {
    const location = objectValue(value);
    if (location == null) return undefined;

    const latitude = normalizeOptionalNumber(location.latitude);
    const longitude = normalizeOptionalNumber(location.longitude);
    if (latitude == null || longitude == null) return undefined;
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return undefined;

    return {
        latitude,
        longitude,
        positionType: normalizeOptionalString(location.positionType) ?? undefined,
        horizontalAccuracy: normalizeOptionalNumber(location.horizontalAccuracy) ?? undefined,
        verticalAccuracy: normalizeOptionalNumber(location.verticalAccuracy) ?? undefined,
        altitude: normalizeOptionalNumber(location.altitude) ?? undefined,
        timeStamp: normalizeOptionalNumber(location.timeStamp) ?? undefined,
        floorLevel: normalizeOptionalNumber(location.floorLevel) ?? undefined,
        isInaccurate: normalizeOptionalBoolean(location.isInaccurate),
        isOld: normalizeOptionalBoolean(location.isOld),
        locationFinished: normalizeOptionalBoolean(location.locationFinished)
    };
};

const normalizeFindMyDeviceAddress = (value: unknown): FindMyDevice["address"] | undefined => {
    const address = objectValue(value);
    if (address == null) return undefined;

    const formattedAddressLines = Array.isArray(address.formattedAddressLines)
        ? address.formattedAddressLines.map(normalizeOptionalString).filter((line): line is string => line != null)
        : [];
    const normalizedAddress = {
        label: normalizeOptionalString(address.label) ?? undefined,
        countryCode: normalizeOptionalString(address.countryCode) ?? undefined,
        administrativeArea: normalizeOptionalString(address.administrativeArea) ?? undefined,
        locality: normalizeOptionalString(address.locality) ?? undefined,
        mapItemFullAddress: normalizeOptionalString(address.mapItemFullAddress) ?? undefined,
        formattedAddressLines
    };
    const hasAddressValue = Object.entries(normalizedAddress).some(([key, fieldValue]) => {
        return key === "formattedAddressLines" ? (fieldValue as string[]).length > 0 : fieldValue != null;
    });
    return hasAddressValue ? normalizedAddress : undefined;
};

export const normalizeFindMyDevice = (value: unknown): FindMyDevice | null => {
    const device = objectValue(value);
    if (device == null) return null;

    const identifier = normalizeOptionalString(device.identifier);
    if (identifier == null) return null;

    const batteryLevel = normalizeOptionalNumber(device.batteryLevel);
    const normalizedBatteryLevel =
        batteryLevel != null && batteryLevel >= 0 && batteryLevel <= 1 ? batteryLevel : undefined;
    const displayName = normalizeOptionalString(device.displayName) ?? undefined;
    const rawDeviceModel =
        normalizeOptionalString(device.rawDeviceModel) ?? normalizeOptionalString(device.model) ?? undefined;

    return {
        id: identifier,
        identifier,
        name: normalizeOptionalString(device.name) ?? undefined,
        deviceDisplayName: displayName,
        modelDisplayName: displayName ?? rawDeviceModel,
        deviceModel: normalizeOptionalString(device.model) ?? rawDeviceModel,
        rawDeviceModel,
        systemVersion: normalizeOptionalString(device.systemVersion) ?? undefined,
        deviceClass: normalizeOptionalString(device.category) ?? undefined,
        batteryLevel: normalizedBatteryLevel,
        batteryStatus: normalizeOptionalString(device.batteryStatus) ?? undefined,
        deviceStatus: normalizeOptionalString(device.deviceConnectedState) ?? undefined,
        deviceDiscoveryId: normalizeOptionalString(device.discoveryIdentifier) ?? undefined,
        baUuid: normalizeOptionalString(device.baIdentifier) ?? undefined,
        address: normalizeFindMyDeviceAddress(device.address),
        location: normalizeFindMyDeviceLocation(device.location),
        crowdSourcedLocation: normalizeFindMyDeviceLocation(device.crowdSourcedLocation)
    };
};

export const normalizeFindMyDevices = (devices: unknown): FindMyDevice[] => {
    if (!Array.isArray(devices)) return [];
    return devices.map(normalizeFindMyDevice).filter((device): device is FindMyDevice => device != null);
};
