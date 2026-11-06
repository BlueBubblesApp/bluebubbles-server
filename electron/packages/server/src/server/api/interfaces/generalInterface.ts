import { app } from "electron";
import macosVersion from "macos-version";

import { Server } from "@server";
import { ServerMetadataResponse } from "@server/types";
import { Device } from "@server/databases/server/entity";
import { UpdateResult } from "@server/api/http/types";
import { FileSystem } from "@server/fileSystem";

const osVersion = macosVersion();

export class GeneralInterface {
    static async getServerMetadata(): Promise<ServerMetadataResponse> {
        return {
            computer_id: Server().computerIdentifier,
            os_version: osVersion,
            server_version: app.getVersion(),
            private_api: Server().repo.getConfig("enable_private_api") as boolean,
            proxy_service: Server().repo.getConfig("proxy_service") as string,
            helper_connected: !!Server().privateApi?.helper,
            detected_icloud: await FileSystem.getIcloudAccount(),
            detected_imessage: await Server().iMessageRepo.getiMessageAccount(),
            macos_time_sync: await FileSystem.getTimeSync(),
            local_ipv4s: FileSystem.getLocalIps("IPv4"),
            local_ipv6s: FileSystem.getLocalIps("IPv6")
        };
    }

    static async addFcmDevice(name: string, identifier: string): Promise<void> {
        // If the device ID exists, update the identifier
        const device = await Server().repo.devices().findOneBy({ name });
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

    static async checkForUpdate(): Promise<UpdateResult> {
        // Check for the update
        const hasUpdate = (await Server().updater?.checkForUpdate({ showUpdateDialog: false })) ?? false;

        // Return the update info if there is an update, return false
        if (hasUpdate)
            return {
                available: true,
                current: app.getVersion(),
                metadata: {
                    version: Server().updater.updateInfo.updateInfo.version,
                    release_date: Server().updater.updateInfo.updateInfo.releaseDate,
                    release_name: Server().updater.updateInfo.updateInfo.releaseName,
                    release_notes: Server().updater.updateInfo.updateInfo.releaseNotes
                }
            };

        return {
            available: false,
            current: app.getVersion(),
            metadata: null
        };
    }

    static async isMessagesRunning(): Promise<boolean> {
        let output = await FileSystem.execShellCommand(`ps aux | grep -v grep | grep -c "Messages.app"`);
        output = output.trim();

        // It should be a number, so we need to test for that
        try {
            const count = Number.parseInt(output);
            return count > 0;
        } catch (ex) {
            return false;
        }
    }
}
