const MULTIPLIER = 10 ** 6;

export const get2001Time = (): number => {
    const appleEpoch = new Date("01-01-2001 00:00:00-0:00");
    return appleEpoch.getTime();
};

export const getDateUsing2001 = (timestamp: number): Date => {
    if (timestamp === 0) return null;

    try {
        return new Date(get2001Time() + timestamp / MULTIPLIER);
    } catch (e) {
        console.log(e.message);
        return null;
    }
};

export const convertDateTo2001Time = (date: Date): number => {
    if (date === null) return 0;

    try {
        return (date.getTime() - get2001Time()) * MULTIPLIER;
    } catch (e) {
        console.log(e.message);
        return null;
    }
};
