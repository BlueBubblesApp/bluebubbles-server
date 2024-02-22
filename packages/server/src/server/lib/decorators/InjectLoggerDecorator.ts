import { Logger } from "../logging/BaseLogger";
import { LoggerRegistry } from "@server/globals";

type PropertyInjector<T> = {
    (target: T): T;
};

export const InjectLogger = <T>(name: string): PropertyInjector<T> => {
    return (target: any) => {
        const value = LoggerRegistry.getLogger(name);
        console.log("INJECTIN VALUE");
        console.log(value);
        console.log(Logger.symbol);
        Reflect.defineProperty(target, Logger.symbol, {
            value,
            writable: false,
            enumerable: false,
            configurable: false
        });
        return target;
    };
};
