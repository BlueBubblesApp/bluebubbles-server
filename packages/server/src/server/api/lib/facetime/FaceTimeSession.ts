import { Server } from "@server";
import { FaceTimeSessionManager } from "./FacetimeSessionManager";
import { NotificationCenterDB } from "@server/databases/notificationCenter/NotiicationCenterRepository";
import { convertDateToCocoaTime } from "@server/databases/imessage/helpers/dateUtil";
import { waitMs } from "@server/helpers/utils";
import { EventEmitter } from "events";

export class FaceTimeSession extends EventEmitter {
    conversationUuid: string;

    callUuid: string;

    url: string;

    admittedParticipants: string[] = [];

    selfAdmissionAwaiter: NodeJS.Timeout = null;

    constructor({
        conversationUuid = null,
        callUuid = null,
    }: {
        conversationUuid?: string,
        callUuid?: string,
    } = {}) {
        super();

        this.conversationUuid = conversationUuid;
        this.callUuid = callUuid;

        FaceTimeSessionManager().addSession(this);

        // After 3 hours, invalidate the FaceTime session
        setTimeout(() => {
            FaceTimeSessionManager().invalidateSession(this.callUuid);
        }, 1000 * 60 * 60 * 3);
    }

    invalidate() {
        this.conversationUuid = null;
        this.callUuid = null;
        this.url = null;
        this.admittedParticipants = [];

        if (this.selfAdmissionAwaiter) {
            clearInterval(this.selfAdmissionAwaiter);
            this.selfAdmissionAwaiter = null;
        }
    }

    private async admitSelfHandler(since: Date): Promise<boolean> {
        // Check the notification center database for a waiting room notification
        const [notifications, _] = await NotificationCenterDB().getRecords({
            sort: "ASC",  // ascending so we can process the oldest first
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

        for (const notification of notifications) {
            // If the notification is for this conversation, admit the participant
            for (const d of notification.data) {
                if (!d.req?.body.includes('join')) continue;

                // Extract the user data
                const userData = d.req?.usda['$objects'] ?? [];

                // If our data is incomplete, skip
                if (userData.length < 10) continue;
                
                const userId = userData[6];
                const conversationId = userData[9];

                // If we'ave already admitted the user, skip
                if (this.admittedParticipants.includes(userId)) continue;

                Server().log(`Admitting ${userId}, into Call: ${conversationId}`, 'debug');
                await Server().privateApi.facetime.admitParticipant(conversationId, userId);
                this.admittedParticipants.push(userId);
                Server().log(`Admitted ${userId}!`, 'debug');

                // Exit if we have admitted a user
                clearInterval(this.selfAdmissionAwaiter);
                return true;
            }
        }

        return false
    }

    async admitSelf(): Promise<void> {
        return await new Promise<void>((resolve, reject) => {
            // Set with ana offset of 5 seconds
            const startDate = new Date((new Date()).getTime() - 5000);
            this.selfAdmissionAwaiter = setInterval(async () => {
                const admitted = await this.admitSelfHandler(startDate);
                if (admitted) {
                    resolve()
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
            Server().log(`Generating FaceTime Link for Call: ${this.callUuid}`);
        } else {
            Server().log(`Generating FaceTime Link For New Call`);
        }
        
        // Invoke the private API
        const result = await Server().privateApi.facetime.generateLink(this.callUuid);
        if (!result?.data?.url) {
            throw new Error("Failed to generate FaceTime link!");
        }

        // Set the url
        this.url = result.data.url;

        // Emit URL to listeners
        this.emit('link', this.url);
        Server().log(`New FaceTime Link Generated: ${this.url}`);
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
        Server().log(`Answering Call: ${this.callUuid}`);
        await Server().privateApi.facetime.answerCall(this.callUuid);
        await waitMs(2000);
    }

    async leaveCall(): Promise<void> {
        Server().log(`Leaving Call: ${this.callUuid}`);
        await Server().privateApi.facetime.leaveCall(this.callUuid);
        await waitMs(2000);
    }

    static async answerIncomingCall(
        callUuid: string,
        onLinkGenerated?: (link: string) => void
    ): Promise<FaceTimeSession> {
        const session = new FaceTimeSession({ callUuid });
        FaceTimeSessionManager().addSession(session);

        session.on('link', (link: string) => {
            if (onLinkGenerated) {
                onLinkGenerated(link);
            }
        })
        
        // Answer the call and generate a link for it.
        await session.answerWithServer();
        await session.generateLink();

        // Wait for the user, and admit them into the call
        await session.admitSelf();

        // Once the user has been admitted, we can leave the call.
        await session.leaveCall();
        return session;
    }

    static async fromGeneratedLink(callUuid: string = null): Promise<FaceTimeSession> {
        const session = new FaceTimeSession({ callUuid });
        FaceTimeSessionManager().addSession(session);

        if (callUuid) {
            Server().log(`Answering Call: ${callUuid}`);
            await Server().privateApi.facetime.answerCall(callUuid);
            await waitMs(2000);
        }

        await session.generateLink();
        return session;
    }
}
