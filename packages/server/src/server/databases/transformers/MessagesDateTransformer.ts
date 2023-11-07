import { ValueTransformer } from "typeorm";
import { convertDateTo2001Time, getDateUsing2001 } from "@server/databases/imessage/helpers/dateUtil";

export const MessagesDateTransformer: ValueTransformer = {
    from: dbValue => getDateUsing2001(dbValue),
    to: entityValue => convertDateTo2001Time(entityValue)
};
