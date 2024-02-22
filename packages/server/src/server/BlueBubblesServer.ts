import { getInjectedLogger } from "./lib/InjectionHelper";
import { InjectLogger } from "./lib/decorators/InjectLoggerDecorator";
import { Logger } from "./lib/logging/BaseLogger";

@InjectLogger("BlueBubblesServerTest")
export class BlueBubblesServerTest {
    private readonly logger: Logger;

    constructor() {
        console.log("const");
        console.log(this.logger);
        this.logger = Reflect.get(this, Logger.symbol) as Logger;
        console.log("after reflect");
        console.log(this.logger);
        // this.logger = getInjectedLogger(this);
        // this.logger.info("Hello, World!")
    }

    test() {
        console.log("test");
        console.log(this.logger);
    }
}

interface MyLogger {
    log(message: string): void; // Define the interface for your custom logger
}

const loggerToken = Symbol.for("logger");

type PropertyInjector<T> = {
    (target: T): T;
};

function injectPrivate<T extends MyLogger>(token: symbol, value: T): PropertyInjector<T> {
    return (target: any) => {
        Reflect.defineProperty(target, token, {
            value,
            writable: false,
            enumerable: false,
            configurable: false
        });
        return target;
    };
}

// Example usage
class CustomLogger implements MyLogger {
    log(message: string): void {
        // Implement your custom logging logic here
        console.log(`[CustomLogger] ${message}`); // Example using console for demonstration
    }
}

@injectPrivate(loggerToken, new CustomLogger())
class MyClass {
    private readonly logger: MyLogger;

    constructor() {
        this.logger = Reflect.get(this, loggerToken);
    }

    public doSomething() {
        this.logger.log("Doing something...");
    }
}

const myInstance = new MyClass();
myInstance.doSomething(); // Logs to CustomLogger
