import { app } from "electron";
import * as macosVersion from "macos-version";

import { Server } from "@server/index";
import { ServerMetadataResponse } from "@server/types";
import { Device } from "@server/databases/server/entity";

const osVersion = macosVersion();

export class GeneralRepo {
    static getServerMetadata(): ServerMetadataResponse {
        return {
            os_version: osVersion,
            server_version: app.getVersion(),
            private_api: Server().repo.getConfig("enable_private_api") as boolean,
            proxy_service: Server().repo.getConfig("proxy_service") as string,
            helper_connected: (Server().privateApiHelper?.server?.connections ?? 0) > 0
        };
    }

    static async addFcmDevice(name: string, identifier: string): Promise<void> {
        // If the device ID exists, update the identifier
        const device = await Server().repo.devices().findOne({ name });
        if (device) {
            device.identifier = identifier;
            device.last_active = new Date().getTime();
            await Server().repo.devices().save(device);
        } else {
            Server().log(`Registering new client with Google FCM (${name})`);

            const item = new Device();
            item.name = name;
            item.identifier = identifier;
            item.last_active = new Date().getTime();
            await Server().repo.devices().save(item);
        }

        Server().repo.purgeOldDevices();
    }
}
