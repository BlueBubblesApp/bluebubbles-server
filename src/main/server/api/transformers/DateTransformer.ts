import { ValueTransformer } from "typeorm";
import { convertDateTo2001Time, getDateUsing2001 } from "@server/api/imessage/helpers/dateUtil";

export const DateTransformer: ValueTransformer = {
    from: dbValue => getDateUsing2001(dbValue),
    to: entityValue => convertDateTo2001Time(entityValue)
};
