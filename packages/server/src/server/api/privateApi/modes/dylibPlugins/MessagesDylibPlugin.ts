import { isMinBigSur, isMinMonterey, isMinSequoia } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
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

    protected async afterClientRegistration(): Promise<void> {
        if (isMinSequoia || Server().findMyCache.getAll().length > 0) return;

        const allowFindMyAppFallback = Boolean(Server().repo.getConfig("open_findmy_on_startup"));
        await FindMyInterface.refreshFriends(allowFindMyAppFallback);
    }
}
