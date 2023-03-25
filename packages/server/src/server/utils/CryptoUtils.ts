import { createHash } from "crypto";


export const generateMd5Hash = (data: Buffer): string => {
    return createHash("md5").update(data).digest("hex");
};