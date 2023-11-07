import { BrowserWindow } from "electron";

export class Window {
    instance: BrowserWindow = null;

    get window(): BrowserWindow {
        return this.instance;
    }

    build(): Window {
        throw new Error("Method not implemented.");
    }
}
