import { ValueTransformer } from "typeorm";
import { convertDateTo2001Time, getCocoaDate } from "@server/databases/imessage/helpers/dateUtil";

export const MessagesDateTransformer: ValueTransformer = {
    from: dbValue => getCocoaDate(dbValue),
    to: entityValue => convertDateTo2001Time(entityValue)
};
