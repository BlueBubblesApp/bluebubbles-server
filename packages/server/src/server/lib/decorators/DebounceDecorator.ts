import { waitMs } from "@server/helpers/utils";

const timeouts = new Map<string, { promise: Promise<any>; timeoutId: NodeJS.Timeout }>();

/**
 * Debounces an async function, ensuring that only one call is executed within the
 * specified timeframe. Subsequent calls within the timeout reset the timer.
 * The decorated function returns the promise of the last invoked call.
 * Optionally cancels any pending invocations.
 */
export const DebounceSubsequentWithWait = <T extends (...args: any[]) => any>(
    name: string,
    timeoutMs: number,
    cancelPrevious?: boolean // Optional flag to cancel previous calls
): MethodDecorator => {
    return (_target: any, _propertyKey: string | symbol, descriptor: PropertyDescriptor) => {
        const originalMethod = descriptor.value;

        descriptor.value = async function (...args: any[]): Promise<ReturnType<T>> {
            const existingTimeout = timeouts.get(name);

            if (existingTimeout && cancelPrevious) {
                clearTimeout(existingTimeout.timeoutId);
                timeouts.delete(name);
            }

            let resolve: (value: any) => void;
            let reject: (reason?: any) => void;

            const promise = new Promise<ReturnType<T>>((res, rej) => {
                resolve = res;
                reject = rej;
            });

            const timeoutId = setTimeout(async () => {
                try {
                    const result = await originalMethod.apply(this, args);
                    resolve(result);
                } catch (ex) {
                    reject(ex);
                } finally {
                    timeouts.delete(name);
                }
            }, timeoutMs);

            timeouts.set(name, { promise, timeoutId });
            return promise;
        };

        return descriptor;
    };
};