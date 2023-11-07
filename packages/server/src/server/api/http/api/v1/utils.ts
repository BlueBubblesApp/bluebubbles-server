import { safeTrim } from "@server/helpers/utils";

export const parseWithQuery = (query: string | string[], lower = true): string[] => {
    if (query == null) return [];

    let output: string[] = [];
    if (typeof query === "string") {
        output = (query ?? '')
            .split(",")
            .map(e => safeTrim(e))
            .filter(e => e && e.length > 0);
    } else if (Array.isArray(query)) {
        output = (query ?? [])
            .filter((e: any) => typeof e === "string")
            .map((e: string) => safeTrim(e))
            .filter(e => e && e.length > 0);
    }

    if (lower) {
        output = output.map(e => e.toLowerCase());
    }

    return output;
};