import { ValueTransformer } from "typeorm";
import { NSAttributedString, Unarchiver } from "node-typedstream";
import { Server } from "@server";
import { isEmpty } from "@server/helpers/utils";

export const AttributedBodyTransformer: ValueTransformer = {
    from: dbValue => {
        try {
            const attributedBody = Unarchiver.open(dbValue, Unarchiver.BinaryDecoding.decodable).decodeAll();
            if (isEmpty(attributedBody)) return null;

            let body = null;
            if (Array.isArray(attributedBody)) {
                body = attributedBody.map(i => {
                    if (i.values) {
                        return i.values.filter((e: any) => {
                            return e && e instanceof NSAttributedString;
                        });
                    } else {
                        return i;
                    }
                });
            } else {
                body = attributedBody;
            }

            // Make sure we don't have nested arrays
            if (Array.isArray(body)) {
                body = body.flat();
            }

            // Make sure all outputs are arrays
            if (!Array.isArray(body)) {
                body = [body];
            }

            return body;
        } catch (e: any) {
            Server().log(`Failed to deserialize archive: ${e.message}`, "debug");
        }

        return null;
    },
    to: _ => null
};
