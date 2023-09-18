import "zx/globals";
import fs from "fs";
import { isMinBigSur, isMinMonterey } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { stopMessages } from "@server/api/v1/apple/scripts";

const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";


export class MessagesDylibPlugin extends DylibPlugin {

    get dylibPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.dylib");
    }

    get parentProcessPath() {
        // Paths are different on Pre/Post Catalina.
        // We are gonna test for both just in case an app was installed prior to the OS upgrade.
        const possiblePaths = [
            "/System/Applications/Messages.app/Contents/MacOS/Messages",
            "/Applications/Messages.app/Contents/MacOS/Messages"
        ];

        // Return the first path that exists
        for (const path of possiblePaths) {
            const exists = fs.existsSync(path);
            if (exists) return path;
        }

        return null;
    }

    async stopParentProcess(): Promise<void> {
        await FileSystem.executeAppleScript(stopMessages());
    }
}