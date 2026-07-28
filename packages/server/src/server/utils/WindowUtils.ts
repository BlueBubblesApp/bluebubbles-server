import type { BrowserWindow } from "electron";

export const minimizeWindowIfRequested = (startMinimized: boolean, window: BrowserWindow | null): boolean => {
    if (!startMinimized || !window) return false;

    window.minimize();
    return true;
};
