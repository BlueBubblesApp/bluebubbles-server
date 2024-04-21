import { ValueTransformer } from "typeorm";
import { convertAttributedBody } from "../imessage/helpers/utils";

export const AttributedBodyTransformer: ValueTransformer = {
    from: dbValue => convertAttributedBody(dbValue),
    to: _ => null
};
