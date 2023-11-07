import "zx/globals";
import fs from "fs";
import { waitMs } from "@server/helpers/utils";
import { Server } from "@server";
import { ProcessPromise } from "zx";
import { FileSystem } from "@server/fileSystem";
import { hideApp } from "@server/api/apple/scripts";

export abstract class DylibPlugin {
    name: string = null;

    parentApp: string = null;

    isStopping = false;

    dylibProcess: ProcessPromise<any>;

    dylibFailureCounter = 0;

    dylibLastErrorTime = 0;

    abstract get dylibPath(): string;

    constructor(name: string) {
        this.name = name;
    }

    async stopParentProcess(): Promise<void> {
        Server().log(`Killing process: ${this.parentApp}`, "debug");
        await FileSystem.killProcess(this.parentApp);
    }

    get parentProcessPath(): string | null {
        // Paths are different on Pre/Post Catalina.
        // We are gonna test for both just in case an app was installed prior to the OS upgrade.
        const possiblePaths = [
            `/System/Applications/${this.parentApp}.app/Contents/MacOS/${this.parentApp}`,
            `/Applications/${this.parentApp}.app/Contents/MacOS/${this.parentApp}`
        ];

        // Return the first path that exists
        for (const path of possiblePaths) {
            const exists = fs.existsSync(path);
            if (exists) return path;
        }

        return null;
    }

    locateDependencies() {
        if (!fs.existsSync(this.dylibPath)) {
            throw new Error(`Unable to locate embedded ${this.name} DYLIB! Please reinstall the app.`);
        }

        if (!fs.existsSync(this.parentProcessPath)) {
            throw new Error(
                `Unable to locate ${this.name} parent process! Please give the BlueBubbles Server Full Disk Access.`
            );
        }
    }

    async injectPlugin() {
        Server().log(`Injecting ${this.name} DYLIB...`, "debug");

        // Clear the markers
        this.dylibFailureCounter = 0;
        this.dylibLastErrorTime = 0;

        // If there are 5 failures in a row, we'll stop trying to start it
        const parentPath = this.parentProcessPath;
        if (!parentPath) {
            throw new Error(`Unable to locate ${this.name} parent process!`);
        }

        while (this.dylibFailureCounter < 5) {
            try {
                // Stop the running Messages app
                try {
                    await this.stopParentProcess();
                    await waitMs(1000);
                } catch {
                    // Ignore. This is most likely due to an osascript error.
                    // Which we don't want to stop the dylib from starting.
                }

                // Execute shell command to start the dylib.
                // eslint-disable-next-line max-len
                this.dylibProcess = $`DYLD_INSERT_LIBRARIES=${this.dylibPath} ${this.parentProcessPath}`;

                // HIde the app after 5 seconds
                setTimeout(() => {
                    this.hideApp();
                }, 4000);

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
                    Server().log(
                        `Failed to start ${this.name} DYLIB after 5 tries: ${ex?.message ?? String(ex)}`,
                        "error"
                    );
                }
            }
        }

        if (this.dylibFailureCounter >= 5) {
            Server().log(`Failed to start ${this.name} DYLIB 3 times in a row, giving up...`, "error");
        }
    }

    async hideApp() {
        try {
            await FileSystem.executeAppleScript(hideApp(this.parentApp));
        } catch (ex) {
            console.log(ex);
            // Don't do anything
        }
    }

    async waitForDylibDeath(): Promise<void> {
        if (this.dylibProcess == null) return;

        return new Promise((resolve, _) => {
            // Catch the error so the promise doesn't throw a no-catch error.
            this.dylibProcess
                .catch(() => {
                    /** Do nothing */
                })
                .finally(resolve);
        });
    }

    async stop() {
        this.isStopping = true;

        let killedDylib = false;
        try {
            this.dylibFailureCounter = 0;
            if (this.dylibProcess != null && !(this.dylibProcess?.child?.killed ?? false)) {
                Server().log(`Killing ${this.name} DYLIB...`, "debug");
                await this.dylibProcess.kill(9);
                killedDylib = true;
            }
        } catch (ex) {
            Server().log(`Failed to stop ${this.name} DYLIB! Error: ${ex.toString()}`, "debug");
        }

        // Wait for the dylib to die
        if (killedDylib) {
            await this.waitForDylibDeath();
        }

        this.isStopping = false;
    }
}
