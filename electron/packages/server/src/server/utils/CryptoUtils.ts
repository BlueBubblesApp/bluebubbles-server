import { createHash, randomBytes } from "crypto";


export const generateMd5Hash = (data: Buffer): string => {
    return createHash("md5").update(data).digest("hex");
};

export const generateRandomString = (length: number): string => {
    return randomBytes(Math.ceil(length / 2)).toString('hex');
};