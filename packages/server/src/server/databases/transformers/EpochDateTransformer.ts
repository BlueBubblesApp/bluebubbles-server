import { ValueTransformer } from "typeorm";

export const EpochDateTransformer: ValueTransformer = {
    from: dbValue => {
        if (dbValue === undefined) return undefined;
        if (dbValue === null) return null;
        return new Date(dbValue);
    },
    to: entityValue => {
        if (entityValue === undefined) return undefined;
        if (entityValue === null) return null;
        return entityValue.getTime();
    }
};
