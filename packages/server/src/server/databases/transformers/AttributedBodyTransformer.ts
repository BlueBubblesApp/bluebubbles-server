import { Server } from "@server/index";
import { ValueTransformer } from "typeorm";

export const AttributedBodyTransformer: ValueTransformer = {
    from: dbValue => Server().swiftHelperService.deserializeAttributedBody(dbValue),
    to: null
};
