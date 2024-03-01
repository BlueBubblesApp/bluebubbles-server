import { Server } from "@server";
import fs from "fs";
import { isMinBigSur, isMinHighSierra } from "@server/env";
import { checkPrivateApiStatus, isNotEmpty } from "@server/helpers/utils";
import { bytesToBase64 } from "byte-base64";

export class iCloudInterface {
    static async getAccountInfo() {
        checkPrivateApiStatus();
        if (!isMinHighSierra) {
            throw new Error("This API is only available on macOS Big Sur and newer!");
        }

        const data = await Server().privateApi.cloud.getAccountInfo();
        return data.data;
    }

    static async getContactCard(address: string = null, loadAvatar = true) {
        checkPrivateApiStatus();
        if (!isMinBigSur) {
            throw new Error("This API is only available on macOS Monterey and newer!");
        }

        const data = await Server().privateApi.cloud.getContactCard(address);
        const avatarPath = data?.data?.avatar_path;
        if (isNotEmpty(avatarPath) && loadAvatar) {
            data.data.avatar = bytesToBase64(fs.readFileSync(avatarPath));
            delete data.data.avatar_path;
        }

        return data.data;
    }

    static async modifyActiveAlias(alias: string) {
        checkPrivateApiStatus();
        const accountInfo = await this.getAccountInfo();
        const aliases = (accountInfo.vetted_aliases ?? []).map((e: any) => e.Alias);
        if (!aliases.includes(alias)) {
            throw new Error(`Alias, "${alias}" is not assigned/enabled for your iCloud account!`);
        }

        await Server().privateApi.cloud.modifyActiveAlias(alias);
    }
}
