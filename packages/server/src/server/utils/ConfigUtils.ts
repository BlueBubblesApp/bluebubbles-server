import { Server } from "@server";


export const getStartDelay = (): number => {
    const startDelayVal: any= (Server().repo.getConfig('start_delay') ?? '0');
    let startDelay = 0;
    if (typeof startDelayVal === 'boolean' && startDelayVal === true) {
        startDelay = 1;
    } else if (typeof startDelayVal === 'boolean' && startDelayVal === false) {
        startDelay = 0;
    } else {
        startDelay = Number.parseInt(startDelayVal);
    }

    return startDelay;
}