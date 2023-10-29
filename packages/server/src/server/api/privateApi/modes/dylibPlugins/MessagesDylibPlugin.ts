import "zx/globals";
import { isMinBigSur, isMinMonterey } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";

const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";

export class MessagesDylibPlugin extends DylibPlugin {
    parentApp = "Messages";

    get dylibPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.dylib");
    }
}
