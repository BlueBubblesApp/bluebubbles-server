import { isMinBigSur, isMinMonterey } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { isNotEmpty } from "@server/helpers/utils";
import { FindMyInterface } from "@server/api/interfaces/findMyInterface";
import path from "path";

const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";

export class MessagesDylibPlugin extends DylibPlugin {
    tag = "MessagesDylibPlugin";

    parentApp = "Messages";

    bundleIdentifier = "com.apple.MobileSMS";

    get dylibPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.dylib");
    }

    get isEnabled() {
        return Server().repo.getConfig("enable_private_api") as boolean;
    }

    async injectPlugin(_?: () => void): Promise<void> {
        return await super.injectPlugin(async () => {
            // If we've already cached some locations, we don't need to again
            if (Server().findMyCache.getAll().length > 0) return;

            // Only open the FindMy App if the user wants to
            const openFindMy = Server().repo.getConfig("open_findmy_on_startup") as boolean;
            const locations = await FindMyInterface.refreshFriends(openFindMy);
            if (isNotEmpty(locations)) {
                Server().findMyCache.addAll(locations);
            }
        });
    }
}
