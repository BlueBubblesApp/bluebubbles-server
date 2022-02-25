export enum MetadataDataTypes {
    String = 0,
    Int = 1,
    Float = 2,
    Bool = 3
}

export type Metadata = {
    [key: string]: string | number | boolean;
};

export type MetadataKeyMap = {
    [key: string]: MetadataKV;
};

export type MetadataKV = {
    dataType: MetadataDataTypes;
    metaKey: string;
};

export type AudioMetadata = {
    bytes?: number;
    bitRate?: number;
    sampleRate?: number;
    duration?: number;
};

export const AudioMetadataKeys: MetadataKeyMap = {
    kMDItemAudioBitRate: {
        dataType: MetadataDataTypes.Int,
        metaKey: "bitRate"
    },
    kMDItemAudioSampleRate: {
        dataType: MetadataDataTypes.Int,
        metaKey: "sampleRate"
    },
    kMDItemDurationSeconds: {
        dataType: MetadataDataTypes.Float,
        metaKey: "duration"
    },
    kMDItemFSSize: {
        dataType: MetadataDataTypes.Int,
        metaKey: "bytes"
    }
};

export type VideoMetadata = {
    bytes?: number;
    height?: number;
    width?: number;
    audioBitRate?: number;
    videoBitRate?: number;
    duration?: number;
    profileName?: string;
};

export const VideoMetadataKeys: MetadataKeyMap = {
    kMDItemAudioBitRate: {
        dataType: MetadataDataTypes.Int,
        metaKey: "audioBitRate"
    },
    kMDItemVideoBitRate: {
        dataType: MetadataDataTypes.Int,
        metaKey: "videoBitRate"
    },
    kMDItemPixelHeight: {
        dataType: MetadataDataTypes.Int,
        metaKey: "height"
    },
    kMDItemPixelWidth: {
        dataType: MetadataDataTypes.Float,
        metaKey: "width"
    },
    kMDItemFSSize: {
        dataType: MetadataDataTypes.Int,
        metaKey: "bytes"
    },
    kMDItemDurationSeconds: {
        dataType: MetadataDataTypes.Float,
        metaKey: "duration"
    },
    kMDItemProfileName: {
        dataType: MetadataDataTypes.String,
        metaKey: "profileName"
    }
};

export type ImageMetadata = {
    altitude?: number;
    aperture?: number;
    bitsPerSample?: number;
    colorSpace?: string;
    exposureTimeSeconds?: number;
    withFlash?: boolean;
    focalLength?: number;
    size?: number;
    latitude?: number;
    longitude?: number;
    orientation?: number;
    height?: number;
    width?: number;
    pixelCount?: number;
    withRedEye?: boolean;
    heightDpi?: number;
    widthDpi?: number;
    withWhiteBalance?: boolean;
    profileName?: string;
    deviceMake?: string;
    deviceModel?: string;
};

export const ImageMetadataKeys: MetadataKeyMap = {
    kMDItemAcquisitionMake: {
        dataType: MetadataDataTypes.String,
        metaKey: "deviceMake"
    },
    kMDItemAcquisitionModel: {
        dataType: MetadataDataTypes.String,
        metaKey: "deviceModel"
    },
    kMDItemAltitude: {
        dataType: MetadataDataTypes.Float,
        metaKey: "altitude"
    },
    kMDItemAperture: {
        dataType: MetadataDataTypes.Float,
        metaKey: "aperture"
    },
    kMDItemBitsPerSample: {
        dataType: MetadataDataTypes.Int,
        metaKey: "bitsPerSample"
    },
    kMDItemColorSpace: {
        dataType: MetadataDataTypes.String,
        metaKey: "colorSpace"
    },
    kMDItemExposureTimeSeconds: {
        dataType: MetadataDataTypes.Float,
        metaKey: "exposureTimeSeconds"
    },
    kMDItemFlashOnOff: {
        dataType: MetadataDataTypes.Bool,
        metaKey: "withFlash"
    },
    kMDItemFocalLength: {
        dataType: MetadataDataTypes.Float,
        metaKey: "focalLength"
    },
    kMDItemFSSize: {
        dataType: MetadataDataTypes.Int,
        metaKey: "size"
    },
    kMDItemLatitude: {
        dataType: MetadataDataTypes.Float,
        metaKey: "latitude"
    },
    kMDItemLongitude: {
        dataType: MetadataDataTypes.Float,
        metaKey: "longitude"
    },
    kMDItemOrientation: {
        dataType: MetadataDataTypes.Int,
        metaKey: "orientation"
    },
    kMDItemPixelHeight: {
        dataType: MetadataDataTypes.Int,
        metaKey: "height"
    },
    kMDItemPixelWidth: {
        dataType: MetadataDataTypes.Int,
        metaKey: "width"
    },
    kMDItemPixelCount: {
        dataType: MetadataDataTypes.Int,
        metaKey: "pixelCount"
    },
    kMDItemRedEyeOnOff: {
        dataType: MetadataDataTypes.Bool,
        metaKey: "withRedEye"
    },
    kMDItemResolutionWidthDPI: {
        dataType: MetadataDataTypes.Int,
        metaKey: "widthDpi"
    },
    kMDItemResolutionHeightDPI: {
        dataType: MetadataDataTypes.Int,
        metaKey: "heightDpi"
    },
    kMDItemWhiteBalance: {
        dataType: MetadataDataTypes.Bool,
        metaKey: "withWhiteBalance"
    },
    kMDItemProfileName: {
        dataType: MetadataDataTypes.String,
        metaKey: "profileName"
    }
};
