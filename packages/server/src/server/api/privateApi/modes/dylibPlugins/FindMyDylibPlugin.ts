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
        const privateApiEnabled = Boolean(Server().repo.getConfig("enable_private_api"));
        const openFindMyOnStartup = Boolean(Server().repo.getConfig("open_findmy_on_startup"));
        return privateApiEnabled && openFindMyOnStartup && isMinSequoia;
    }

    async injectPlugin(_?: () => void | Promise<void>): Promise<void> {
        if (!this.isEnabled) return;

        await FileSystem.requestFindMyAutomationPermissions();
        return super.injectPlugin(async () => {
            if (Server().findMyCache.getAll().length > 0) return;

            await FindMyInterface.refreshFriends(false);
        });
    }
}
