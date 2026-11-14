import { isMinSequoia } from "@server/env";
import { DylibPlugin } from ".";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { FindMyInterface } from "@server/api/interfaces/findMyInterface";
import path from "path";
import {
    FIND_MY_HELPER_CONNECTION_TIMEOUT_MS,
    FIND_MY_SYSTEM_SETUP_GUIDANCE,
    FindMyHelperReadiness
} from "@server/api/privateApi/FindMyHelperReadiness";

const FIND_MY_HELPER_RESOURCE_DIRECTORY = "macos11";
const FIND_MY_STOP_GRACE_MS = 2000;

export class FindMyDylibPlugin extends DylibPlugin {
    tag = "FindMyDylibPlugin";

    parentApp = "FindMy";

    bundleIdentifier = "com.apple.findmy";

    private state: Pick<FindMyHelperReadiness, "status" | "reason" | "message"> = {
        status: "disabled",
        reason: null,
        message: "Find My helper is disabled."
    };

    private registrationTimer: NodeJS.Timeout | null = null;

    private acceptRegistration = false;

    private retryInProgress: Promise<FindMyHelperReadiness> | null = null;

    private stopInProgress: Promise<void> | null = null;

    private initializationAbort: AbortController | null = null;

    get dylibPath() {
        return path.join(
            FileSystem.resources,
            "private-api",
            FIND_MY_HELPER_RESOURCE_DIRECTORY,
            "BlueBubblesFindMyHelper.dylib"
        );
    }

    get isEnabled() {
        const privateApiEnabled = Boolean(Server().repo.getConfig("enable_private_api"));
        const openFindMyOnStartup = Boolean(Server().repo.getConfig("open_findmy_on_startup"));
        return privateApiEnabled && openFindMyOnStartup && isMinSequoia;
    }

    get readiness(): FindMyHelperReadiness {
        if (!this.isEnabled) {
            return {
                required: isMinSequoia,
                requested: false,
                status: "disabled",
                reason: null,
                message: isMinSequoia
                    ? "Enable the Private API and Open FindMy App on Startup to use the Find My helper."
                    : "This macOS version does not require the Find My helper."
            };
        }

        if (this.state.status === "ready" && !Server().privateApi.hasClient(this.bundleIdentifier)) {
            this.state = {
                status: "unavailable",
                reason: "connection_lost",
                message: "Find My helper disconnected. Retry to check its availability again."
            };
        }

        return { required: true, requested: true, ...this.state };
    }

    protected get restartParentAfterExit(): boolean {
        return false;
    }

    private clearRegistrationTimer(): void {
        if (this.registrationTimer) clearTimeout(this.registrationTimer);
        this.registrationTimer = null;
    }

    protected onParentProcessStarted(): void {
        if (!this.stopRequested && this.state.status === "initializing") this.acceptRegistration = true;
    }

    private startRegistrationDeadline(): void {
        this.clearRegistrationTimer();
        this.registrationTimer = setTimeout(() => {
            this.registrationTimer = null;
            this.acceptRegistration = false;
            this.state = {
                status: "unavailable",
                reason: "registration_timeout",
                message: "Find My helper did not connect within 30 seconds. " + FIND_MY_SYSTEM_SETUP_GUIDANCE
            };
            this.log.warn(this.state.message);
            // Stop only the child created by this attempt, not another user's/app's process.
            void this.terminateAttempt().catch((error: any) => {
                this.log.warn(`Unable to stop the unconnected Find My child: ${error?.message ?? String(error)}`);
            });
        }, FIND_MY_HELPER_CONNECTION_TIMEOUT_MS);
    }

    async injectPlugin(): Promise<void> {
        if (!this.isEnabled || this.injectionRunning || this.state.status === "unavailable") return;

        this.state = {
            status: "initializing",
            reason: null,
            message: "Checking whether macOS permits the Find My helper to load."
        };
        // Ignore an old helper ping while preparing or stopping its previous host.
        this.acceptRegistration = false;
        this.initializationAbort = new AbortController();
        this.startRegistrationDeadline();
        try {
            await super.injectPlugin();
        } catch (error: any) {
            this.log.warn(`Unable to initialize the Find My helper: ${error?.message ?? String(error)}`);
        } finally {
            this.clearRegistrationTimer();
            this.acceptRegistration = false;
            this.initializationAbort = null;
            if (!this.isEnabled) {
                this.state = { status: "disabled", reason: null, message: "Find My helper is disabled." };
            } else if (["initializing", "ready"].includes(this.state.status)) {
                this.state = {
                    status: "unavailable",
                    reason: this.state.status === "ready" ? "connection_lost" : "launch_failed",
                    message: "Find My helper stopped before it could remain connected. " + FIND_MY_SYSTEM_SETUP_GUIDANCE
                };
            }
        }
    }

    async stop(): Promise<void> {
        // An explicit service stop/restart is a new verification opportunity. The
        // deadline callback uses terminateAttempt directly to retain its failure.
        this.state = { status: "disabled", reason: null, message: "Find My helper is disabled." };
        await this.terminateAttempt();
    }

    private async terminateAttempt(): Promise<void> {
        if (this.stopInProgress) return this.stopInProgress;
        this.stopInProgress = this.stopCurrentAttempt();
        try {
            await this.stopInProgress;
        } finally {
            this.stopInProgress = null;
        }
    }

    private waitForAttemptCompletion(): Promise<boolean> {
        return new Promise(resolve => {
            const timer = setTimeout(() => resolve(false), FIND_MY_STOP_GRACE_MS);
            this.injectionCompletion.then(() => {
                clearTimeout(timer);
                resolve(true);
            });
        });
    }

    private async stopCurrentAttempt(): Promise<void> {
        this.acceptRegistration = false;
        this.clearRegistrationTimer();
        this.stopRequested = true;
        this.initializationAbort?.abort();
        if (this.injectionRunning) {
            const child = this.currentParentProcess;
            await child?.kill();
            if (await this.waitForAttemptCompletion()) return;
            if (child && this.currentParentProcess === child) await child.kill("SIGKILL");
            if (await this.waitForAttemptCompletion()) return;
            this.state = {
                status: "unavailable",
                reason: "launch_failed",
                message:
                    "The previous Find My attempt has not stopped. Close its permission dialog " +
                    "or restart the Server before retrying."
            };
        }
    }

    async retry(): Promise<FindMyHelperReadiness> {
        if (!this.isEnabled || this.readiness.status === "ready" || this.state.status === "initializing") {
            return this.readiness;
        }
        if (this.retryInProgress) return this.retryInProgress;
        this.retryInProgress = this.performRetry();
        try {
            return await this.retryInProgress;
        } finally {
            this.retryInProgress = null;
        }
    }

    private async performRetry(): Promise<FindMyHelperReadiness> {
        await this.stop();
        if (!this.isEnabled) return this.readiness;
        if (this.injectionRunning) return this.readiness;
        this.state = { status: "disabled", reason: null, message: "Find My helper is disabled." };
        void this.injectPlugin();
        return this.readiness;
    }

    protected async prepareForInjection(): Promise<void> {
        await FileSystem.requestFindMyAutomationPermissions(this.initializationAbort?.signal);
    }

    protected async afterClientRegistration(): Promise<void> {
        if (!this.acceptRegistration || this.stopRequested || !this.isEnabled) return;
        this.clearRegistrationTimer();
        this.state = { status: "ready", reason: null, message: "Find My helper is connected." };
        const refreshes: Array<{ name: string; refresh: () => Promise<unknown> }> = [];
        if (Server().findMyFriendsCache.getAll().length === 0) {
            refreshes.push({ name: "Friends", refresh: () => FindMyInterface.refreshFriends(false) });
        }
        if (Server().findMyDevicesCache.getAll().length === 0) {
            refreshes.push({ name: "Devices", refresh: () => FindMyInterface.refreshDevices() });
        }
        await Promise.all(
            refreshes.map(async ({ name, refresh }) => {
                try {
                    await refresh();
                } catch (error: any) {
                    this.log.warn(`Unable to initialize Find My ${name}: ${error?.message ?? String(error)}`);
                }
            })
        );
    }
}
