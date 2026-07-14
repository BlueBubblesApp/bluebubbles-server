import { FindMyItem, FindMyDevice, FindMyLocationItem } from "@server/api/lib/findmy/types";

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
    const output: any = { ...item };

    if (Array.isArray(output.title)) {
        output.title = output.title.find((value: unknown) => typeof value === "string" && value.length > 0) ?? null;
    } else if (output.title != null && typeof output.title !== "string") {
        output.title = String(output.title);
    }

    if (Array.isArray(output.coordinates)) {
        output.coordinates = [
            Number(output.coordinates[0] ?? 0),
            Number(output.coordinates[1] ?? 0)
        ];
    } else if (output.coordinates == null) {
        output.coordinates = null;
    }

    if (output.last_updated == null) output.last_updated = null;
    if (output.is_locating_in_progress == null) output.is_locating_in_progress = false;

    return output;
};

export const normalizeFindMyLocationItems = (items: FindMyLocationItem[]): FindMyLocationItem[] => {
    if (!Array.isArray(items)) return [];
    return items.map(normalizeFindMyLocationItem);
};
