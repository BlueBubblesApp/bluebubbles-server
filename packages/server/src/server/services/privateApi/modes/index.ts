export abstract class PrivateApiMode {

    install(...args: any): Promise<void> {
        throw new Error("Method not implemented.");
    }

    uninstall(...args: any): Promise<void> {
        throw new Error("Method not implemented.");
    }

    abstract start(): Promise<void>;

    abstract stop(): Promise<void>;
}