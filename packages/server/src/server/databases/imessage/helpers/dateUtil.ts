import macosVersion from "macos-version";
import CompareVersions from "compare-versions";

const osVersion = macosVersion();
const MULTIPLIER = 10 ** 6;

/**
 * Gets the seconds since Jan 1st, 2001. We need this because apple uses this
 * as their EPOCH time, rather than the true EPOCH
 */
export const get2001Time = (): number => {
    const appleEpoch = new Date("01-01-2001 00:00:00-0:00");
    return appleEpoch.getTime();
};

/**
 * Converts a seconds-since-2001 timestamp to a date object
 *
 * @param timestamp The seconds-since-2001
 */
export const getDateUsing2001 = (timestamp: number, multiplier = MULTIPLIER): Date => {
    if (timestamp === 0 || timestamp == null) return null;

    try {
        let ts = get2001Time();
        if (!osVersion || CompareVersions(osVersion, "10.13.0") >= 0) {
            ts += timestamp / multiplier;
        } else {
            ts += timestamp * 1000;
        }

        return new Date(ts);
    } catch (e: any) {
        console.log(e.message);
        return null;
    }
};

export const getCocoaDate = (timestamp: number): Date => {
    if (timestamp === 0 || timestamp == null) return null;

    try {
        let ts = get2001Time();
        ts += timestamp * 1000;
        return new Date(ts);
    } catch (e: any) {
        console.log(e.message);
        return null;
    }
};

/**
 * Converts a date object to a seconds-since-2001 timestamp
 *
 * @param timestamp The date object to convert
 */
export const convertDateTo2001Time = (date: Date): number => {
    if (date === null) return 0;

    try {
        let ts = date.getTime() - get2001Time();
        if (!osVersion || CompareVersions(osVersion, "10.13.0") >= 0) ts *= MULTIPLIER;
        else ts /= 1000;

        return ts;
    } catch (e: any) {
        console.log(e.message);
        return null;
    }
};

export const convertDateToCocoaTime = (date: Date): number => {
    if (date === null) return 0;

    try {
        let ts = date.getTime() - get2001Time();
        ts /= 1000;
        return ts;
    } catch (e: any) {
        console.log(e.message);
        return null;
    }
};
