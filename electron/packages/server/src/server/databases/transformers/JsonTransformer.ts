import { ValueTransformer } from "typeorm";

export const JsonTransformer: ValueTransformer = {
    from: dbValue => JSON.parse(dbValue),
    to: entityValue => JSON.stringify(entityValue)
};
