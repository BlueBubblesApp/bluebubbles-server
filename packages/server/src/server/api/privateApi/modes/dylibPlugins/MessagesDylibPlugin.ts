import "zx/globals";
import fs from "fs";
import { isMinBigSur, isMinMonterey } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { stopMessages } from "@server/api/apple/scripts";

const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";

export class MessagesDylibPlugin extends DylibPlugin {
    parentApp = "Messages";

    get dylibPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.dylib");
    }

    async stopParentProcess(): Promise<void> {
        await FileSystem.executeAppleScript(stopMessages());
    }
}
