import { Loggable } from "@server/lib/logging/Loggable";

export interface PrivateApiModeConstructor {
    install(...args: any): Promise<any | void>;
    uninstall(...args: any): Promise<any | void>;
    new (): PrivateApiMode;
}

export abstract class PrivateApiMode extends Loggable {
    tag = "PrivateApiMode";

    isStopping = false;

    static install(...args: any): Promise<any | void> {
        throw new Error("Method not implemented.");
    }

    static uninstall(...args: any): Promise<any | void> {
        throw new Error("Method not implemented.");
    }

    abstract start(): Promise<void>;

    abstract stop(): Promise<void>;

    async restart() {
        await this.stop();
        await this.start();
    }
}
