import "zx/globals";
import { isMinBigSur, isMinMonterey, waitMs } from "@server/helpers/utils";
import { PrivateApiMode } from ".";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { stopMessages } from "@server/api/v1/apple/scripts";
import { ProcessPromise } from "zx";
import { MacForgeMode } from "./MacForgeMode";

const macVer = isMinMonterey ? "macos11" : isMinBigSur ? "macos11" : "macos10";


export class ProcessDylibMode extends PrivateApiMode {

    dylibProcess: ProcessPromise<any>;

    dylibFailureCounter = 0;

    dylibLastErrorTime = 0;

    static get dylbiPath() {
        return path.join(FileSystem.resources, "private-api", macVer, "BlueBubblesHelper.dylib");
    }

    static messagesPath = "/System/Applications/Messages.app/Contents/MacOS/Messages";
    
    static async install() {
        if (!fs.existsSync(ProcessDylibMode.dylbiPath)) {
            await Server().repo.setConfig("private_api_mode", "macforge");
            throw new Error("Unable to locate embedded Private API DYLIB! Falling back to MacForge Bundle.");
        }

        const messagesPath = "/System/Applications/Messages.app/Contents/MacOS/Messages";
        if (!fs.existsSync(messagesPath)) {
            await Server().repo.setConfig("private_api_mode", "macforge");
            throw new Error("Unable to locate Messages.app! Falling back to MacForge Bundle.");
        }

        await MacForgeMode.uninstall();
    }

    static async uninstall() {
        // Nothing to do here
    }

    async start() {
        // Call a different function so this can properly be awaited/returned.
        this.manageProcess();
    }

    async manageProcess() {
        // Clear the markers
        this.dylibFailureCounter = 0;
        this.dylibLastErrorTime = 0;

        // If there are 5 failures in a row, we'll stop trying to start it
        while (this.dylibFailureCounter < 5) {
            try {
                // Stop the running Messages app
                try {
                    await FileSystem.executeAppleScript(stopMessages());
                    await waitMs(1000);
                } catch {
                    // Ignore. This is most likely due to an osascript error.
                    // Which we don't want to stop the dylib from starting.
                }

                // Execute shell command to start the dylib.
                // eslint-disable-next-line max-len
                this.dylibProcess = $`DYLD_INSERT_LIBRARIES=${ProcessDylibMode.dylbiPath} ${ProcessDylibMode.messagesPath}`;
                await this.dylibProcess;
            } catch (ex: any) {
                if (this.isStopping) return;

                // If the last time we errored was more than 15 seconds ago, reset the counter.
                // This would indicate that the dylib was running, but then crashed.
                // Rather than an immediate crash.
                if (Date.now() - this.dylibLastErrorTime > 15000) {
                    this.dylibFailureCounter = 0;
                }

                this.dylibFailureCounter += 1;
                this.dylibLastErrorTime = Date.now();
                if (this.dylibFailureCounter >= 5) {
                    Server().log(`Failed to start dylib after 5 tries: ${ex?.message ?? String(ex)}`, "error");
                }
            }
        }

        if (this.dylibFailureCounter >= 5) {
            Server().log("Failed to start Private API DYLIB 3 times in a row, giving up...", "error");
        }
    }

    async waitForDylibDeath(): Promise<void> {
        if (this.dylibProcess == null) return;

        return new Promise((resolve, _) => {
            // Catch the error so the promise doesn't throw a no-catch error.
            this.dylibProcess.catch(() => { /** Do nothing */ }).finally(resolve);
        });
    }

    async stop() {
        this.isStopping = true;

        let killedDylib = false;
        try {
            this.dylibFailureCounter = 0;
            if (this.dylibProcess != null && !(this.dylibProcess?.child?.killed ?? false)) {
                Server().log("Killing BlueBubblesHelper DYLIB...", "debug");
                await this.dylibProcess.kill(9);
                killedDylib = true;
            }
        } catch (ex) {
            Server().log(`Failed to stop Private API Helper! Error: ${ex.toString()}`, 'debug');
        }

        // Wait for the dylib to die
        if (killedDylib) {
            await this.waitForDylibDeath();
        }

        this.isStopping = false;
    }
}