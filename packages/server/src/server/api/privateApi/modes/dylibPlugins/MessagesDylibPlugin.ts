import { isMinBigSur, isMinMonterey } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
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

}
