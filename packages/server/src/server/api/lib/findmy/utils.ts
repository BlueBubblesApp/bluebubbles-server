import type { FindMyItem, FindMyDevice, FindMyLocationItem } from "@server/api/lib/findmy/types";

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

    // Extras from FindMyItem
    identifier: item?.identifier,
    productIdentifier: item?.productIdentifier,
    role: item?.role,
    serialNumber: item?.serialNumber,
    lostModeMetadata: item?.lostModeMetadata,
    groupIdentifier: item?.groupIdentifier,
    groupName: item.groupName,
    isAppleAudioAccessory: item?.isAppleAudioAccessory,
    capabilities: item?.capabilities,
});

export const normalizeFindMyLocationItem = (item: FindMyLocationItem): FindMyLocationItem => {
    const output: Record<string, any> = { ...item };

    const optionalString = (value: unknown): string | null => {
        if (typeof value !== "string") return null;
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : null;
    };

    const optionalNumber = (value: unknown): number | null => {
        if (value == null || (typeof value === "string" && value.trim().length === 0)) return null;
        const numericValue = Number(value);
        return Number.isFinite(numericValue) ? numericValue : null;
    };

    if (Array.isArray(output.title)) {
        output.title = output.title.map(optionalString).find((value: string | null) => value != null) ?? null;
    } else {
        output.title = optionalString(output.title);
    }

    const latitude = Array.isArray(output.coordinates) ? optionalNumber(output.coordinates[0]) : null;
    const longitude = Array.isArray(output.coordinates) ? optionalNumber(output.coordinates[1]) : null;
    output.coordinates = latitude != null && longitude != null ? [latitude, longitude] : null;

    output.handle = optionalString(output.handle);
    for (const field of ["long_address", "short_address", "subtitle"] as const) {
        output[field] = optionalString(output[field]);
    }

    output.last_updated = optionalNumber(output.last_updated);
    output.is_locating_in_progress =
        output.is_locating_in_progress === true || output.is_locating_in_progress === 1 ? 1 : 0;
    if (!["legacy", "live", "shallow"].includes(output.status)) output.status = "legacy";

    return output as FindMyLocationItem;
};

export const normalizeFindMyLocationItems = (
    items: FindMyLocationItem[] | null | undefined
): FindMyLocationItem[] => {
    if (!Array.isArray(items)) return [];
    return items.map(normalizeFindMyLocationItem).filter(item => item.handle != null);
};
