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
    if (value == null || (typeof value === "string" && value.trim().length === 0)) return null;
    const numericValue = Number(value);
    return Number.isFinite(numericValue) ? numericValue : null;
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

export const normalizeFindMyFriendLocation = (location: FindMyFriendLocation): FindMyFriendLocation => {
    const untrustedLocation = location as unknown as Record<string, unknown>;
    const untrustedStatus = untrustedLocation.status;
    const status = isFindMyFriendStatus(untrustedStatus) ? untrustedStatus : "legacy";

    return {
        ...location,
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
        status
    };
};

export const normalizeFindMyFriendLocations = (
    locations: FindMyFriendLocation[] | null | undefined
): FindMyFriendLocation[] => {
    if (!Array.isArray(locations)) return [];
    return locations.map(normalizeFindMyFriendLocation).filter(location => location.handle != null);
};
