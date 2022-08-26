import { safeTrim } from "@server/helpers/utils";

export const parseWithQuery = (query: string | string[]): string[] => {
    if (query == null) return [];
    if (typeof query === "string") {
        return (query ?? '')
            .toLowerCase().split(",")
            .map(e => safeTrim(e))
            .filter(e => e && e.length > 0);
    } else if (Array.isArray(query)) {
        return (query ?? [])
            .filter((e: any) => typeof e === "string")
            .map((e: string) => safeTrim(e.toLowerCase()))
            .filter(e => e && e.length > 0);
    }

    return [];
};