import { isMinBigSur, isMinMonterey } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import path from "path";

const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";

export class FaceTimeDylibPlugin extends DylibPlugin {
    tag = "FaceTimeDylibPlugin";

    parentApp = "FaceTime";

    bundleIdentifier = "com.apple.FaceTime";

    // Other tools that hook FaceTime can be listed here so they're injected alongside this helper
    companionConfigKey = "ft_companion_dylibs";

    get isEnabled() {
        return (Server().repo.getConfig("enable_ft_private_api") as boolean) && isMinBigSur;
    }

    get dylibPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesFaceTimeHelper.dylib");
    }
}
