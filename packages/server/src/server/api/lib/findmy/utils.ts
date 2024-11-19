import { FindMyItem, FindMyDevice } from "@server/api/lib/findmy/types";

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
