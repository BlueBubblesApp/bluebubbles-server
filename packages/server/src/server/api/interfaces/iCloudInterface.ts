import { Server } from "@server";
import { isNotEmpty } from "@server/helpers/utils";
import { bytesToBase64 } from "byte-base64";

export class iCloudInterface {
    static async getAccountInfo() {
        const data = await Server().privateApi.cloud.getAccountInfo();
        return data.data;
    }

    static async getContactCard(loadAvatar = true) {
        const data = await Server().privateApi.cloud.getContactCard();
        const avatarPath = data?.data?.avatar_path;
        if (isNotEmpty(avatarPath) && loadAvatar) {
            data.data.avatar = bytesToBase64(fs.readFileSync(avatarPath));
            delete data.data.avatar_path;
        }

        return data.data;
    }

    static async modifyActiveAlias(alias: string) {
        const accountInfo = await this.getAccountInfo();
        const aliases = (accountInfo.vetted_aliases ?? []).map((e: any) => e.Alias);
        if (!aliases.includes(alias)) {
            throw new Error(`Alias, "${alias}" is not assigned/enabled for your iCloud account!`);
        }

        await Server().privateApi.cloud.modifyActiveAlias(alias);
    }
}
