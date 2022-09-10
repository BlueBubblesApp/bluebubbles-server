import { ValueTransformer } from "typeorm";
import {NSAttributedString, Unarchiver} from "node-typedstream";
import {Server} from "@server";

export const AttributedBodyTransformer: ValueTransformer = {
    from: dbValue => {
        try {
            const attributedBody = Unarchiver.open(dbValue).decodeAll()[0].values[0];
            if (attributedBody instanceof NSAttributedString) {
                return attributedBody;
            }
        } catch (e: any) {
            Server().log(`Failed to deserialize attributedBody: ${e.message}`, "debug");
        }
        return null;
    },
    to: entityValue => null
};
