import { FindMyDevice } from "./types";

export class FindMyDevicesCache {
    private devicesByIdentifier = new Map<string, FindMyDevice>();

    updateAll(devices: FindMyDevice[]): FindMyDevice[] {
        const updatedDevices: FindMyDevice[] = [];
        for (const device of devices) {
            const identifier = device.identifier ?? device.id;
            if (identifier == null || identifier.length === 0) continue;

            this.devicesByIdentifier.set(identifier, device);
            updatedDevices.push(device);
        }
        return updatedDevices;
    }

    replaceAll(devices: FindMyDevice[]): FindMyDevice[] {
        this.devicesByIdentifier.clear();
        return this.updateAll(devices);
    }

    getAll(): FindMyDevice[] {
        return Array.from(this.devicesByIdentifier.values());
    }
}
