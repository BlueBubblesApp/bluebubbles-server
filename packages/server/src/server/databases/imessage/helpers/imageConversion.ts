export type ImageConversion = {
    sourceExtension: "heic" | "heif" | "tiff";
    outputExtension: "jpeg" | "png";
    outputMimeType: "image/jpeg" | "image/png";
};

export const getImageConversion = (uti: string | null, mimeType: string | null): ImageConversion | null => {
    if (uti === "public.heic" || mimeType?.startsWith("image/heic")) {
        return {
            sourceExtension: "heic",
            outputExtension: "png",
            outputMimeType: "image/png"
        };
    }

    if (uti === "public.heif" || mimeType?.startsWith("image/heif")) {
        return {
            sourceExtension: "heif",
            outputExtension: "png",
            outputMimeType: "image/png"
        };
    }

    if (uti === "public.tiff" || mimeType?.startsWith("image/tiff") || mimeType?.endsWith("tif")) {
        return {
            sourceExtension: "tiff",
            outputExtension: "jpeg",
            outputMimeType: "image/jpeg"
        };
    }

    return null;
};

export const getConvertedImageName = (name: string, conversion: ImageConversion): string => {
    const sourceSuffix = `.${conversion.sourceExtension}`;
    const outputSuffix = `.${conversion.outputExtension}`;
    let outputName = name;

    if (outputName.toLowerCase().endsWith(sourceSuffix)) {
        outputName = outputName.slice(0, -sourceSuffix.length);
    }

    if (outputName.toLowerCase().endsWith(outputSuffix)) return outputName;
    return `${outputName}${outputSuffix}`;
};
