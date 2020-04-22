import * as macosVersion from "macos-version";

const osVersion = macosVersion();
const MULTIPLIER = 10 ** 6;

export const get2001Time = (): number => {
    const appleEpoch = new Date("01-01-2001 00:00:00-0:00");
    return appleEpoch.getTime();
};

export const getDateUsing2001 = (timestamp: number): Date => {
    if (timestamp === 0) return null;

    try {
        let ts = get2001Time();
        if (osVersion >= "10.13.0") ts += timestamp / MULTIPLIER;
        else ts += timestamp * 1000;

        return new Date(ts);
    } catch (e) {
        console.log(e.message);
        return null;
    }
};

export const convertDateTo2001Time = (date: Date): number => {
    if (date === null) return 0;

    try {
        let ts = date.getTime() - get2001Time();
         if (osVersion >= "10.13.0") ts *= MULTIPLIER;
         else ts /= 1000;

        return ts;
    } catch (e) {
        console.log(e.message);
        return null;
    }
};
