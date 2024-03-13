import { Server } from "@server";
import { FaceTimeSessionManager } from "./FacetimeSessionManager";
import { NotificationCenterDB } from "@server/databases/notificationCenter/NotiicationCenterRepository";
import { convertDateToCocoaTime } from "@server/databases/imessage/helpers/dateUtil";
import { waitMs } from "@server/helpers/utils";
import { v4 } from "uuid";
import { ScheduledService } from "../../../lib/ScheduledService";
import { Loggable } from "../../../lib/logging/Loggable";

export enum FaceTimeSessionStatus {
    UNKNOWN = 0,
    ANSWERED = 1,
    OUTGOING = 3,
    INCOMING = 4,
    DISCONNECTED = 6
}

export const callStatusMap: Record<number, string> = {
    [FaceTimeSessionStatus.UNKNOWN]: "unknown",
    [FaceTimeSessionStatus.ANSWERED]: "answered",
    [FaceTimeSessionStatus.OUTGOING]: "outgoing",
    [FaceTimeSessionStatus.INCOMING]: "incoming",
    [FaceTimeSessionStatus.DISCONNECTED]: "disconnected"
};

export class FaceTimeSession extends Loggable {
    tag = "FaceTimeSession";

    uuid: string;

    conversationUuid: string;

    callUuid: string;

    url: string;

    admittedParticipants: string[] = [];

    selfAdmissionService: ScheduledService = null;

    createdAt: Date;

    status: FaceTimeSessionStatus = FaceTimeSessionStatus.UNKNOWN;

    constructor({
        callUuid = null,
        conversationUuid = null,
        addToManager = true
    }: {
        callUuid?: string;
        conversationUuid?: string;
        addToManager?: boolean;
    } = {}) {
        super();

        this.uuid = v4();

        this.createdAt = new Date();
        this.callUuid = callUuid;
        this.conversationUuid = conversationUuid;

        if (addToManager) {
            FaceTimeSessionManager().addSession(this);
        }

        // After 3 hours, invalidate the FaceTime session
        setTimeout(() => {
            this.invalidate();
        }, 1000 * 60 * 60 * 3);
    }

    invalidate() {
        this.status = FaceTimeSessionStatus.DISCONNECTED;
        this.conversationUuid = null;
        this.callUuid = null;
        this.url = null;
        this.admittedParticipants = [];

        if (this.selfAdmissionService) {
            this.selfAdmissionService.stop();
            this.selfAdmissionService = null;
        }

        this.emit("disconnected");
    }

    update(session: FaceTimeSession) {
        if (session.status === FaceTimeSessionStatus.DISCONNECTED) {
            this.invalidate();
        } else if (this.status === FaceTimeSessionStatus.INCOMING) {
            if ([FaceTimeSessionStatus.INCOMING, FaceTimeSessionStatus.ANSWERED].includes(session.status)) {
                this.status = FaceTimeSessionStatus.ANSWERED;
                this.emit("answered", true);
            }
        }
    }

    private async admitSelfHandler(since: Date): Promise<boolean> {
        // Check the notification center database for a waiting room notification
        this.log.debug(`Checking for FaceTime admission notifications since: ${since}`);
        const [notifications, _] = await NotificationCenterDB().getRecords({
            sort: "ASC", // ascending so we can process the oldest first
            where: [
                {
                    statement: `app.identifier = :identifier`,
                    args: {
                        identifier: "com.apple.facetime"
                    }
                },
                {
                    statement: `record.delivered_date >= :deliveredDate`,
                    args: {
                        deliveredDate: convertDateToCocoaTime(since)
                    }
                }
            ]
        });

        this.log.debug(`Found ${notifications.length} notification(s)...`);
        for (const notification of notifications) {
            // If the notification is for this conversation, admit the participant
            for (const d of notification.data) {
                if (!d.req?.body.includes("join")) {
                    this.log.debug(`Notification body does not contain a join request: ${String(d.req?.body)}`);
                    continue;
                }

                // Extract the user data
                const userData = d.req?.usda["$objects"] ?? [];

                // If our data is incomplete, skip
                if (userData.length < 10) {
                    this.log.debug("User data did not contain enough parts!");
                    continue;
                }

                const userId = userData[6];
                const conversationId = userData[9];

                // If we'ave already admitted the user, skip
                if (this.admittedParticipants.includes(userId)) {
                    this.log.debug(`User already admitted! (ID: ${userId})`);
                    continue;
                }

                this.log.debug(`Admitting ${userId}, into Call: ${conversationId}`);
                await Server().privateApi.facetime.admitParticipant(conversationId, userId);
                this.admittedParticipants.push(userId);
                this.log.debug(`Admitted ${userId}!`);

                // Exit if we have admitted a user
                this.selfAdmissionService.stop();
                return true;
            }
        }

        return false;
    }

    async admitSelf(): Promise<void> {
        return await new Promise<void>((resolve, reject) => {
            // Set with an offset of 5 seconds
            const startDate = new Date(new Date().getTime() - 5000);
            this.selfAdmissionService = new ScheduledService(async () => {
                const admitted = await this.admitSelfHandler(startDate);
                if (admitted) {
                    resolve();
                }

                // If the current time is more than 2 minutes, throw an error and leave the call.
                const now = new Date().getTime();
                if (now - startDate.getTime() > 1000 * 60 * 2) {
                    await this.leaveCall();
                    this.invalidate();
                    reject("Failed to admit self into FaceTime call!. No join requests detected in 2 minutes.");
                }
            }, 1000);
        });
    }

    async generateLink(): Promise<string> {
        if (this.callUuid) {
            this.log.info(`Generating FaceTime Link for Call: ${this.callUuid}`);
        } else {
            this.log.info(`Generating FaceTime Link For New Call`);
        }

        // Invoke the private API
        const result = await Server().privateApi.facetime.generateLink(this.callUuid);
        if (!result?.data?.url) {
            throw new Error("Failed to generate FaceTime link!");
        }

        // Set the url
        this.url = result.data.url;

        // Emit URL to listeners
        this.emit("link", this.url);
        this.log.info(`New FaceTime Link Generated: ${this.url}`);
        return this.url;
    }

    async admitParticipant(handleUuid: string): Promise<string[]> {
        // Invoke the private API
        const result = await Server().privateApi.facetime.admitParticipant(this.conversationUuid, handleUuid);
        if (!result?.data?.admittedParticipants) {
            throw new Error("Failed to admit participant!");
        }

        // Set the admitted participants
        this.admittedParticipants = result.data.admittedParticipants;
        return this.admittedParticipants;
    }

    async answerWithServer(): Promise<void> {
        this.log.info(`Answering Call: ${this.callUuid}`);

        // Initialize the listener
        const waiter = this.waitForAnswer();

        // Answer the call
        await Server().privateApi.facetime.answerCall(this.callUuid);

        // Wait for the listener to receive the answered event
        await waiter;
    }

    private async waitForAnswer(): Promise<void> {
        await new Promise<void>((resolve, reject) => {
            this.on("answered", () => {
                resolve();
            });

            // If the call is not answered in 30 seconds, reject
            setTimeout(() => {
                reject(new Error("Timed out waiting for FaceTime call to connect!"));
            }, 1000 * 30);
        });

        // Wait 4 seconds to prevent crashing on Sonoma (and potentially other environments).
        // 1 second is too short. 3 seconds will work 75% of the time. 4 seconds for good measure.
        // Unfortunately, there isn't a good wait to detect when the call is ready to be used.
        await waitMs(4000);
    }

    async leaveCall(): Promise<void> {
        this.log.info(`Leaving Call: ${this.callUuid}`);
        await Server().privateApi.facetime.leaveCall(this.callUuid);
        await waitMs(2000);
    }

    async admitAndLeave(): Promise<void> {
        this.log.debug("Waiting to admit self...");

        // Wait for the user, and admit them into the call
        await this.admitSelf();

        // Wait 15 seconds for the person to join
        this.log.debug("Waiting 15 seconds for you to connect...");
        await waitMs(15000);

        // Once the user has been admitted, we can leave the call.
        this.log.debug("Leaving the call...");
        await this.leaveCall();
    }

    static async answerIncomingCall(
        callUuid: string,
        onLinkGenerated?: (link: string) => void
    ): Promise<FaceTimeSession> {
        let session = FaceTimeSessionManager().findSession(callUuid);
        session ??= new FaceTimeSession({ callUuid });

        if (session.status === FaceTimeSessionStatus.DISCONNECTED) {
            throw new Error("Unable to answer call! The call has already ended.");
        }

        session.status = FaceTimeSessionStatus.INCOMING;

        session.on("link", (link: string) => {
            if (onLinkGenerated) {
                onLinkGenerated(link);
            }
        });

        // Answer the call and generate a link for it.
        await session.answerWithServer();
        await session.generateLink();
        await session.admitAndLeave();
        return session;
    }

    static async fromGeneratedLink(callUuid: string = null): Promise<FaceTimeSession> {
        const session = new FaceTimeSession({ callUuid });

        if (callUuid) {
            if (session.status === FaceTimeSessionStatus.DISCONNECTED) {
                throw new Error("Unable to generate link for call! The call has already ended.");
            }

            session.status = FaceTimeSessionStatus.INCOMING;
            await session.answerWithServer();
        } else {
            session.status = FaceTimeSessionStatus.OUTGOING;
        }

        await session.generateLink();
        return session;
    }

    static fromEvent(event: any, addToManager = false): FaceTimeSession {
        const session = new FaceTimeSession({ callUuid: event.call_uuid ?? null, addToManager });
        session.status = event.call_status;
        return session;
    }
}
