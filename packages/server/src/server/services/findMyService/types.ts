export interface FindMyDevice {
    deviceModel?: string;
    lowPowerMode?: unknown;
    passcodeLength?: number;
    itemGroup?: unknown;
    id?: string;
    batteryStatus?: string;
    audioChannels?: Array<unknown>;
    lostModeCapable?: unknown;
    snd?: unknown;
    batteryLevel?: number;
    locationEnabled?: unknown;
    isConsideredAccessory?: unknown;
    address?: FindMyAddress;
    location?: FindMyLocation;
    modelDisplayName?: string;
    deviceColor?: unknown;
    activationLocked?: unknown;
    rm2State?: number;
    locFoundEnabled?: unknown;
    nwd?: unknown;
    deviceStatus?: string;
    remoteWipe?: unknown;
    fmlyShare?: unknown;
    thisDevice?: unknown;
    lostDevice?: unknown;
    lostModeEnabled?: unknown;
    deviceDisplayName?: string;
    safeLocations?: Array<unknown>;
    name?: string;
    canWipeAfterLock?: unknown;
    isMac?: unknown;
    rawDeviceModel?: string;
    baUuid?: string;
    trackingInfo?: unknown;
    features?: Record<string, boolean>;
    deviceDiscoveryId?: string;
    prsId?: string;
    scd?: unknown;
    locationCapable?: unknown;
    remoteLock?: unknown;
    wipeInProgress?: unknown;
    darkWake?: unknown;
    deviceWithYou?: unknown;
    maxMsgChar?: number;
    deviceClass?: string;
    crowdSourcedLocation: FindMyLocation;

    // Extra properties from FindMyItem
    role?: FindMyItem["role"];
    serialNumber?: string;
    lostModeMetadata?: FindMyItem["lostModeMetadata"]
}

export interface FindMyItem {
    partInfo?: unknown;
    isFirmwareUpdateMandatory: boolean;
    productType: {
        type: string;
        productInformation: {
            manufacturerName: string;
            modelName: string;
            productIdentifier: number;
            vendorIdentifier: number;
            antennaPower: number;
        };
    };
    safeLocations?: Array<unknown>;
    owner: string;
    batteryStatus: number;
    serialNumber: string;
    lostModeMetadata?: null | {
        email: string;
        message: string;
        ownerNumber: string;
        timestamp: number;
    };
    capabilities: number;
    identifier: string;
    address: FindMyAddress;
    location: FindMyLocation;
    productIdentifier: string;
    isAppleAudioAccessory: false;
    crowdSourcedLocation: FindMyLocation;
    groupIdentifier: null;
    role: {
        name: string;
        emoji: string;
        identifier: number;
    };
    systemVersion: string;
    name: string;
}

interface FindMyAddress {
    subAdministrativeArea?: string;
    label?: string;
    streetAddress?: string;
    countryCode?: string;
    stateCode?: string;
    administrativeArea?: string;
    streetName?: string;
    formattedAddressLines: Array<string>;
    mapItemFullAddress?: string;
    fullThroroughfare?: string;
    areaOfInterest?: Array<unknown>;
    locality?: string;
    country?: string;
}

interface FindMyLocation {
    positionType?: string;
    verticalAccuracy?: number;
    longitude?: number;
    floorLevel?: number;
    isInaccurate?: boolean;
    isOld?: boolean;
    horizontalAccuracy?: number;
    latitude?: number;
    timeStamp?: number;
    altitude?: number;
    locationFinished?: boolean;
}
