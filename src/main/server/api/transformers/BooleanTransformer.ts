import { ValueTransformer } from "typeorm";

export const BooleanTransformer: ValueTransformer = {
    from: dbValue => Boolean(dbValue),
    to: entityValue => Number(entityValue)
};
