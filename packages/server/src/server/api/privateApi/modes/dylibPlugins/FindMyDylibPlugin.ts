import { isMinSequoia } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { FindMyInterface } from "@server/api/interfaces/findMyInterface";
import path from "path";

const macVer = "macos11";

export class FindMyDylibPlugin extends DylibPlugin {
    tag = "FindMyDylibPlugin";

    parentApp = "FindMy";

    bundleIdentifier = "com.apple.findmy";

    get dylibPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesFindMyHelper.dylib");
    }

    get isEnabled() {
        return (Server().repo.getConfig("enable_private_api") as boolean) && isMinSequoia;
    }

    async injectPlugin(_?: () => void): Promise<void> {
        return await super.injectPlugin(async () => {
            if (Server().findMyCache.getAll().length > 0) return;

            await FindMyInterface.refreshFriends(false);
        });
    }
}
