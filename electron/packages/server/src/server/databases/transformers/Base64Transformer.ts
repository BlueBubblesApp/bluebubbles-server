import { ValueTransformer } from "typeorm";

export const Base64Transformer: ValueTransformer = {
    from: dbValue => dbValue ? Buffer.from(dbValue, 'base64') : null,
    to: entityValue => entityValue ? entityValue.toString('base64') : null
};
