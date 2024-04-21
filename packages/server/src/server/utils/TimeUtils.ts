
// This function is used to create a timeout that is safe to use with a delay that
// is greater than the maximum 32-bit integer value.
export const safeTimeout = (
    callback: () => void,
    delay: number,
    onNewTimeout?: (newTimeout: NodeJS.Timeout) => void
): NodeJS.Timeout => {
    const max32BitInt = 2147483647;

    // If the delay is less than the max 32-bit integer, create a normal timeout
    if (delay <= max32BitInt) {
        return setTimeout(callback, delay);
    }

    // If the delay is larger than the max 32-bit integer,
    // recursively create a timeout with the max 32-bit integer
    // and call the callback with the remaining delay.
    return setTimeout(() => {
        const newTimeout = safeTimeout(callback, delay - max32BitInt, onNewTimeout);
        if (onNewTimeout) {
            onNewTimeout(newTimeout);
        }
    }, max32BitInt);
};
