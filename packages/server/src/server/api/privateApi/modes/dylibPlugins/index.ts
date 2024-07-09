import fs from "fs";
import { waitMs } from "@server/helpers/utils";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { hideApp } from "@server/api/apple/scripts";
import { Loggable } from "@server/lib/logging/Loggable";
import { ProcessSpawner } from "@server/lib/ProcessSpawner";

export abstract class DylibPlugin extends Loggable {
    tag = "DylibPlugin";

    name: string = null;

    parentApp: string = null;

    bundleIdentifier: string = null;

    isStopping = false;

    isInjecting = false;

    dylibFailureCounter = 0;

    dylibLastErrorTime = 0;

    abstract get isEnabled(): boolean;

    abstract get dylibPath(): string;

    constructor(name: string) {
        super();
        this.name = name;
    }

    async stopParentProcess(): Promise<void> {
        try {
            this.log.debug(`Killing process: ${this.parentApp}`);
            await FileSystem.killProcess(this.parentApp);
        } catch (ex: any) {
            const errStr = (typeof ex === "object" ? ex?.message ?? String(ex) : String(ex)).trim();
            if (!errStr.includes("No matching processes belonging to you were found")) {
                this.log.debug(`Failed to kill parent process (${this.parentApp})! Error: ${errStr}`);
            }
        }
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
        if (!this.isEnabled) return;
        if (!fs.existsSync(this.dylibPath)) {
            throw new Error(`Unable to locate embedded ${this.name} DYLIB! Please reinstall the app.`);
        }

        if (!fs.existsSync(this.parentProcessPath)) {
            throw new Error(
                `Unable to locate ${this.name} parent process! Please give the BlueBubbles Server Full Disk Access.`
            );
        }
    }

    async injectPlugin(onSuccessfulStart: () => void = null) {
        if (!this.isEnabled) return;
        if (this.isInjecting) return;
        this.isInjecting = true;
        this.log.debug(`Injecting ${this.name} DYLIB...`);

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
                await this.stopParentProcess();
                await waitMs(1000);

                // Execute shell command to start the dylib.
                // eslint-disable-next-line max-len
                if (!this.isEnabled || this.isStopping) {
                    this.isInjecting = false;
                    return;
                }

                const spawner = new ProcessSpawner({
                    command: this.parentProcessPath,
                    args: [],
                    verbose: true,
                    logTag: this.parentApp,
                    storeOutput: false,
                    waitForExit: true,
                    restartOnNonZeroExit: false,
                    options: {
                        env: {
                            DYLD_INSERT_LIBRARIES: this.dylibPath
                        }
                    },
                })

                const promise = spawner.execute();

                // Hide the app after 5 seconds
                setTimeout(() => {
                    this.hideApp();
                }, 5000);

                Server().privateApi.on("client-registered", info => {
                    if (info?.process !== this.bundleIdentifier) return;
                    onSuccessfulStart();
                });

                await promise;

                // If it gets here, the dylib exited on its own (code: 0)
                this.log.debug(`DYLIB exited on its own. Restarting...`);
                this.dylibFailureCounter = 0;
            } catch (ex: any) {
                this.log.debug(`Detected DYLIB crash for App ${this.parentApp}. Error: ${ex?.message ?? String(ex)}`);
                if (this.isStopping) {
                    this.isInjecting = false;
                    return;
                }

                // If the last time we errored was more than 15 seconds ago, reset the counter.
                // This would indicate that the dylib was running, but then crashed.
                // Rather than an immediate crash.
                if (Date.now() - this.dylibLastErrorTime > 15000) {
                    this.dylibFailureCounter = 0;
                }

                this.dylibFailureCounter += 1;
                this.dylibLastErrorTime = Date.now();
                if (this.dylibFailureCounter >= 5) {
                    this.log.error(`Failed to start ${this.name} DYLIB after 5 tries: ${ex?.message ?? String(ex)}`);
                }
            }
        }

        if (this.dylibFailureCounter >= 5) {
            this.log.error(`Failed to start ${this.name} DYLIB 3 times in a row, giving up...`);
        }

        this.isInjecting = false;
    }

    async hideApp() {
        try {
            await FileSystem.executeAppleScript(hideApp(this.parentApp));
        } catch (ex) {
            console.log(ex);
            // Don't do anything
        }
    }

    async stop() {
        this.isStopping = true;
        await this.stopParentProcess();
        this.isStopping = false;
    }
}
