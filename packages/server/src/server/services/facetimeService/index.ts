import {
    checkForIncomingFacetime10,
    checkForIncomingFacetime11,
    checkForIncomingFacetime13
} from "@server/api/v1/apple/scripts";
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur, isMinVentura, isNotEmpty, waitMs } from "@server/helpers/utils";
import { INCOMING_FACETIME } from "@server/events";

export class FacetimeService {
    isStopping = false;

    isRunning = false;

    serviceAwaiter: Promise<void> = null;

    isGettingCall = false;

    hadPreviousCall = false;

    notificationSent = false;

    incomingCallListener: NodeJS.Timeout;

    flush() {
        this.isRunning = false;
        this.isStopping = false;
        this.serviceAwaiter = null;
        this.isGettingCall = false;
        this.hadPreviousCall = false;
        this.notificationSent = false;
    }

    async listen({delay = 30000} = {}): Promise<void> {
        if (this.isRunning) {
            Server().log("Facetime listener already running");
            return this.serviceAwaiter;
        }

        if (delay && delay > 0) {
            Server().log(`Delaying FaceTime listener start by ${delay} ms...`);
            await waitMs(delay);
        }

        Server().log("Starting FaceTime listener...");
        this.flush();

        this.isRunning = true;
        this.serviceAwaiter = new Promise((resolve, reject) => {
            const serviceLoop = async () => {
                if (this.isStopping) {
                    return resolve();
                }

                // Check for call applescript
                let facetimeCallIncoming;
                let hasErrored = false;

                try {
                    if (isMinVentura) {
                        facetimeCallIncoming = (
                            await FileSystem.executeAppleScript(checkForIncomingFacetime13())
                        ).replace("\n", ""); // If on macos 13
                    } else if (isMinBigSur) {
                        facetimeCallIncoming = (
                            await FileSystem.executeAppleScript(checkForIncomingFacetime11())
                        ).replace("\n", ""); // If on macos 11 and 12
                    } else {
                        facetimeCallIncoming = (
                            await FileSystem.executeAppleScript(checkForIncomingFacetime10())
                        ).replace("\n", ""); // If on macos 10 and below
                    }
                } catch (e: any) {
                    if ((e?.message ?? "").includes("assistive access")) {
                        Server().log("Facetime listener detected an assistive access error");
                        this.flush();
                        return reject(e);
                    } else if ((e?.message ?? "").includes("can't open default scripting component")) {
                        Server().log("Facetime listener detected an osascript component error");
                        this.flush();
                        return reject(e);
                    } else {
                        Server().log(`Facetime listener AppleScript error: ' + ${e.message}`);
                        hasErrored = true;
                    }
                }

                if (!hasErrored) {
                    // Ignore the notification of a missed Facetime
                    if (
                        facetimeCallIncoming === "now" ||
                        facetimeCallIncoming.endsWith("ago") ||
                        facetimeCallIncoming.endsWith("AM") ||
                        facetimeCallIncoming.endsWith("PM")
                    ) {
                        facetimeCallIncoming = "";
                    }

                    // Set the flag if we have a valid incoming call
                    if (isNotEmpty(facetimeCallIncoming)) {
                        this.isGettingCall = true;
                    } else {
                        this.isGettingCall = false;
                    }

                    // If we haven't sent a notification to the clients, send it.
                    if (this.isGettingCall && !this.notificationSent) {
                        Server().log(`Incoming facetime call from ${facetimeCallIncoming}`);
                        this.notificationSent = true;

                        const jsonData = JSON.stringify({
                            caller: facetimeCallIncoming,
                            timestamp: new Date().getTime()
                        });

                        Server().emitMessage(INCOMING_FACETIME, jsonData, "high");
                    }

                    // Clear the notification sent variable
                    if (!this.isGettingCall && this.notificationSent && this.hadPreviousCall) {
                        this.notificationSent = false;
                    }

                    this.hadPreviousCall = this.isGettingCall;
                }

                setTimeout(serviceLoop, 5000);
            };

            setTimeout(serviceLoop, 0);
        });

        return this.serviceAwaiter;
    }

    async stop() {
        Server().log("Stopping FaceTime listener...");
        if (this.serviceAwaiter && this.isRunning) {
            this.isStopping = true;
            await this.serviceAwaiter;
        }

        this.flush();
    }
}
