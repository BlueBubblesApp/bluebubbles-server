import fs from "fs";
import { waitMs } from "@server/helpers/utils";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { hideApp } from "@server/api/apple/scripts";
import { Loggable } from "@server/lib/logging/Loggable";
import { ProcessSpawner } from "@server/lib/ProcessSpawner";

const APP_HIDE_DELAY_MS = 5000;
const FAILURE_BUDGET_RESET_INTERVAL_MS = 15000;
const MAX_CONSECUTIVE_FAILURES = 5;
const PROCESS_RESTART_DELAY_MS = 1000;

export abstract class DylibPlugin extends Loggable {
    tag = "DylibPlugin";

    name: string = null;

    parentApp: string = null;

    bundleIdentifier: string = null;

    stopRequested = false;

    injectionRunning = false;

    consecutiveFailureCount = 0;

    lastFailureAt = 0;

    private injectionCompletion: Promise<void> = Promise.resolve();

    private resolveInjectionCompletion: (() => void) | null = null;

    abstract get isEnabled(): boolean;

    abstract get dylibPath(): string;

    constructor(name: string) {
        super();
        this.name = name;
    }

    protected prepareForInjection(): Promise<void> {
        return Promise.resolve();
    }

    protected afterClientRegistration(): Promise<void> {
        return Promise.resolve();
    }

    async stopParentProcess(): Promise<void> {
        try {
            this.log.debug(`Killing process: ${this.parentApp}`);
            await FileSystem.killProcess(this.parentApp);
        } catch (error: any) {
            const errorMessage = (typeof error === "object" ? error?.message ?? String(error) : String(error)).trim();
            if (!errorMessage.includes("No matching processes belonging to you were found")) {
                this.log.debug(`Failed to kill parent process (${this.parentApp})! Error: ${errorMessage}`);
            }
        }
    }

    get parentProcessPath(): string | null {
        const candidatePaths = [
            `/System/Applications/${this.parentApp}.app/Contents/MacOS/${this.parentApp}`,
            `/Applications/${this.parentApp}.app/Contents/MacOS/${this.parentApp}`
        ];

        return candidatePaths.find(candidatePath => fs.existsSync(candidatePath)) ?? null;
    }

    locateDependencies() {
        if (!this.isEnabled) return;
        if (!fs.existsSync(this.dylibPath)) {
            throw new Error(`Unable to locate embedded ${this.name} DYLIB! Please reinstall the app.`);
        }

        const parentExecutablePath = this.parentProcessPath;
        if (!parentExecutablePath || !fs.existsSync(parentExecutablePath)) {
            throw new Error(
                `Unable to locate ${this.name} parent process! Please give the BlueBubbles Server Full Disk Access.`
            );
        }
    }

    async injectPlugin(): Promise<void> {
        if (!this.isEnabled || this.injectionRunning) return;

        this.stopRequested = false;
        this.injectionRunning = true;
        this.consecutiveFailureCount = 0;
        this.lastFailureAt = 0;
        this.injectionCompletion = new Promise(resolve => {
            this.resolveInjectionCompletion = resolve;
        });

        let hideTimer: NodeJS.Timeout | null = null;
        const handleClientRegistration = (registration: { process?: string }) => {
            if (registration?.process !== this.bundleIdentifier) return;

            this.afterClientRegistration().catch((error: any) => {
                this.log.warn(`Failed to initialize ${this.name} after injection: ${error?.message ?? String(error)}`);
            });
        };

        try {
            await this.prepareForInjection();
            if (this.stopRequested || !this.isEnabled) return;

            const parentExecutablePath = this.parentProcessPath;
            if (!parentExecutablePath) {
                throw new Error(`Unable to locate ${this.name} parent process!`);
            }

            Server().privateApi.on("client-registered", handleClientRegistration);
            this.log.debug(`Injecting ${this.name} DYLIB...`);

            while (this.consecutiveFailureCount < MAX_CONSECUTIVE_FAILURES) {
                try {
                    await this.stopParentProcess();
                    await waitMs(PROCESS_RESTART_DELAY_MS);

                    if (this.stopRequested || !this.isEnabled) return;

                    const parentProcess = new ProcessSpawner({
                        command: parentExecutablePath,
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
                        }
                    });

                    const parentProcessExit = parentProcess.execute();
                    hideTimer = setTimeout(() => {
                        void this.hideApp();
                    }, APP_HIDE_DELAY_MS);

                    await parentProcessExit;
                    this.log.debug(`${this.name} parent process exited; restarting`);
                    this.consecutiveFailureCount = 0;
                } catch (error: any) {
                    this.log.debug(
                        `Detected DYLIB crash for App ${this.parentApp}. Error: ${error?.message ?? String(error)}`
                    );
                    if (this.stopRequested) return;

                    if (Date.now() - this.lastFailureAt > FAILURE_BUDGET_RESET_INTERVAL_MS) {
                        this.consecutiveFailureCount = 0;
                    }

                    this.consecutiveFailureCount += 1;
                    this.lastFailureAt = Date.now();
                    if (this.consecutiveFailureCount >= MAX_CONSECUTIVE_FAILURES) {
                        this.log.error(
                            `Failed to start ${this.name} DYLIB after ${MAX_CONSECUTIVE_FAILURES} tries: ` +
                                `${error?.message ?? String(error)}`
                        );
                    }
                } finally {
                    if (hideTimer) {
                        clearTimeout(hideTimer);
                        hideTimer = null;
                    }
                }
            }

            this.log.error(
                `Failed to start ${this.name} DYLIB ${MAX_CONSECUTIVE_FAILURES} times in a row, giving up...`
            );
        } finally {
            Server().privateApi.removeListener("client-registered", handleClientRegistration);
            this.injectionRunning = false;
            this.resolveInjectionCompletion?.();
            this.resolveInjectionCompletion = null;
        }
    }

    async hideApp(): Promise<void> {
        try {
            await FileSystem.executeAppleScript(hideApp(this.parentApp));
        } catch (error: any) {
            this.log.debug(`Unable to hide ${this.parentApp}: ${error?.message ?? String(error)}`);
        }
    }

    async stop(): Promise<void> {
        this.stopRequested = true;
        if (!this.injectionRunning) return;

        await this.stopParentProcess();
        await this.injectionCompletion;
    }
}
