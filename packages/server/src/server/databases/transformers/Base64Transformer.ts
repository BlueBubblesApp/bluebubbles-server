import { ValueTransformer } from "typeorm";

export const Base64Transformer: ValueTransformer = {
    from: dbValue => Buffer.from(dbValue, 'base64'),
    to: entityValue => entityValue.toString('base64')
};
