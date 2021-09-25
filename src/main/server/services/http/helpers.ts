import { ImageQuality } from "./types";

export const parseQuality = (value: string): ImageQuality => {
    const opts = ["good", "better", "best"];
    if (opts.includes(value)) return value as ImageQuality;

    // Return best if the value is empty or null
    const missingOpts = [null, undefined, " "];
    if (missingOpts.includes(value)) return "best";

    let parsed: number;
    try {
        parsed = Number.parseInt(value, 10);

        // Map the number only when between 0 - 100
        if (parsed > 0 && parsed < 100) {
            if (parsed <= 50) {
                return "good";
            }

            if (parsed < 75) {
                return "better";
            }
        }
    } catch (ex) {
        // Don't do anything
    }

    // If all the other conditions fail, default to best
    return "best";
};

export const parseNumber = (value: string): number => {
    if (!value) return null;

    let parsed: number;

    try {
        parsed = Number.parseInt(value, 10);
        if (parsed < 0) return null;
    } catch (ex) {
        return null;
    }

    // If all the other conditions fail, default to best
    return parsed;
};
