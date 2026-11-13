export class Completer {
    promise: Promise<any | void>;

    hasCompleted = false;

    private _resolve: (value: any) => void;

    private _reject: (reason?: any) => void;

    static sync() {
        const c = new Completer();
        c.resolve();
        return c;
    }

    constructor() {
        this.promise = new Promise((resolve, reject) => {
            this._resolve = resolve;
            this._reject = reject;
        });
    }

    resolve(value?: any) {
        if (this.hasCompleted) return;
        this.hasCompleted = true;
        this._resolve(value);
    }

    reject(reason?: any) {
        if (this.hasCompleted) return;
        this.hasCompleted = true;
        this._reject(reason);
    }
}
