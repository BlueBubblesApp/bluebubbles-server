import { ValueTransformer } from "typeorm";

export const JsonTransformer: ValueTransformer = {
    from: dbValue => {
        if (dbValue == null) return null;
        if (typeof dbValue === "object") {
            return dbValue;
        }

        return JSON.parse(dbValue);
    },
    to: entityValue => {
        if (entityValue == null) return null;
        if (typeof entityValue === "string") {
            return entityValue;
        }

        return JSON.stringify(entityValue);
    }
};
