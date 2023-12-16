import { ValueTransformer } from "typeorm";

export const BlobStringTransformer: ValueTransformer = {
    from: (dbValue: Buffer) => {
        return dbValue.toString("utf-8");
    },
    to: (entityValue) => {
        return Buffer.from(entityValue, "utf-8");
    }
};
