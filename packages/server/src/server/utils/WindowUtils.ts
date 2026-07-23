import type { BrowserWindow } from "electron";

export const minimizeWindowIfRequested = (startMinimized: boolean, window: BrowserWindow | null): void => {
    if (startMinimized && window) {
        window.minimize();
    }
};
