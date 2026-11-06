import { isNotEmpty } from "@server/helpers/utils";

export class AttributedBodyUtils {
    static extractText(attributedBody: NodeJS.Dict<any> | NodeJS.Dict<any>[]): string | null {
        if (attributedBody == null) return null;
        if (!Array.isArray(attributedBody)) {
            attributedBody = [attributedBody];
        }

        for (const i of (attributedBody as NodeJS.Dict<any>[])) {
            if (isNotEmpty(i?.string)) {
                return i.string;
            }
        }
        
        return null;
    }
}