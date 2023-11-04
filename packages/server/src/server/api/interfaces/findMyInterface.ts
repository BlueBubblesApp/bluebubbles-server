import { Server } from "@server";
import { isMinBigSur } from "@server/env";
import { checkPrivateApiStatus } from "@server/helpers/utils";
import { FindMyService } from "@server/services";

export class findMyInterface {
    static async getFriends() {
        const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        let data = null;
        if (papiEnabled && isMinBigSur) {
            checkPrivateApiStatus();
            const result = await Server().privateApi.findmy.getFriendsLocations();
            data = result?.data;
        } else {
            data = await FindMyService.getFriends();
        }

        return data;
    }
}
