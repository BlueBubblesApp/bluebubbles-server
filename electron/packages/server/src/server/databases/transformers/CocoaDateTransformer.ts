import { ValueTransformer } from "typeorm";
import { convertDateToCocoaTime, getCocoaDate } from "@server/databases/imessage/helpers/dateUtil";

export const CocoaDateTransformer: ValueTransformer = {
    from: dbValue => getCocoaDate(dbValue),
    to: entityValue => convertDateToCocoaTime(entityValue)
};
