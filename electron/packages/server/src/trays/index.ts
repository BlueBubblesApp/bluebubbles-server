import { Tray as ElectronTray } from "electron";

export abstract class Tray {
    instance: ElectronTray;

    abstract build(): Promise<void>;
}
