import * as Jimp from "jimp";
import { encode as blurHashEncode } from "blurhash";

export const getBlurHash = async (image: Jimp) => {
    let blurhash: string = null;

    try {
        // If the image is "too big", rescale it so blurhash is computed faster
        if (image.getWidth() > 32) image.scaleToFit(32, Jimp.AUTO, Jimp.RESIZE_BILINEAR);

        // Compute blurhash
        blurhash = blurHashEncode(Uint8ClampedArray.from(image.bitmap.data), image.getWidth(), image.getHeight(), 1, 1);
    } catch (ex) {
        console.log(ex);
        console.log(`Could not compute blurhash`);
    }

    return blurhash;
};
