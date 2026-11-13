export type FindMyHelperStatus = "disabled" | "initializing" | "ready" | "unavailable";

export type FindMyHelperReadiness = {
    required: boolean;
    requested: boolean;
    status: FindMyHelperStatus;
    reason: "registration_timeout" | "launch_failed" | "connection_lost" | "not_started" | null;
    message: string;
};

export const FIND_MY_HELPER_CONNECTION_TIMEOUT_MS = 30_000;

export const FIND_MY_SYSTEM_SETUP_GUIDANCE =
    "Check macOS Automation permissions and the Private API system requirements. " +
    "Review the Server logs for launch or connection failures, then retry. " +
    "BlueBubbles does not change system security settings.";

export class FindMyUnavailableError extends Error {
    readonly readiness: FindMyHelperReadiness;

    constructor(readiness: FindMyHelperReadiness) {
        super(readiness.message);
        this.name = "FindMyUnavailableError";
        this.readiness = readiness;
    }
}
