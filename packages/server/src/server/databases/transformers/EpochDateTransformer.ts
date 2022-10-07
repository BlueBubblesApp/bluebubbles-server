import { ValueTransformer } from "typeorm";

export const EpochDateTransformer: ValueTransformer = {
    from: dbValue => {
        console.log("transofrming");
        console.log(dbValue);
        if (dbValue === undefined) return undefined;
        if (dbValue === null) return null;
        console.log(dbValue);
        console.log(new Date(dbValue));
        return new Date(dbValue);
    },
    to: entityValue => {
        console.log("transforming - saving");
        console.log(entityValue);
        if (entityValue === undefined) return undefined;
        if (entityValue === null) return null;
        console.log("not empty");
        console.log(entityValue.getTime());
        return entityValue.getTime();
    }
};
