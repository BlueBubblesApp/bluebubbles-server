import { waitMs } from "@server/helpers/utils";

const timeouts = new Map<string, Promise<any>>();

/**
 * This function debounces an async function,
 * ensuring that only the first call is executed
 * within the specified time frame. All subsequent
 * calls will simply return the result of the first.
 * The initial call will be executed after the timeout.
 *
 * @param name 
 * @returns 
 */
export const DebounceSubsequentWithWait = <T extends (...args: any[]) => any>(
    name: string,
    timeoutMs: number | (() => number)
): MethodDecorator => {
    return (_target: any, _propertyKey: string | symbol, descriptor: PropertyDescriptor) => {
        const originalMethod = descriptor.value;

        descriptor.value = async function (...args: any[]): Promise<ReturnType<T>> {
            const executor = timeouts.get(name);
            if (executor) return await executor;

            // Wrap the original method in a promise.
            // This will call the original function after the timeout.
            const promiseWrapper = async () => {
                try {
                    // Resolved lazily (rather than once at decoration time) so config-driven
                    // values (e.g. the user's poll interval setting) can change at runtime.
                    const resolvedTimeoutMs = typeof timeoutMs === "function" ? timeoutMs() : timeoutMs;
                    await waitMs(resolvedTimeoutMs);
                    const result = await originalMethod.apply(this, args);
                    timeouts.delete(name);
                    return result;
                } catch (ex) {
                    timeouts.delete(name);
                    throw ex;
                }
            }

            const promise = promiseWrapper.call(this);
            timeouts.set(name, promise);
            return await promise;
        };

        return descriptor;
    };
};