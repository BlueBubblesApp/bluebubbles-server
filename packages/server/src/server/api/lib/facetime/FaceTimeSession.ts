import { Server } from "@server";
import { FaceTimeSessionManager } from "./FacetimeSessionManager";
import { NotificationCenterDB } from "@server/databases/notificationCenter/NotiicationCenterRepository";
import { convertDateToCocoaTime } from "@server/databases/imessage/helpers/dateUtil";

export class FaceTimeSession {
    conversationUuid: string;

    callUuid: string;

    url: string;

    admittedParticipants: string[];

    selfAdmissionAwaiter: NodeJS.Timeout = null;

    constructor({
        conversationUuid = null,
        callUuid = null,
    }: {
        conversationUuid?: string,
        callUuid?: string,
    } = {}) {
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

    private async admitSelfHandler(since: Date): Promise<void> {
        // Check the notification center database for a waiting room notification
        const [notifications, _] = await NotificationCenterDB().getRecords({
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
            console.log(notification);
            console.log(notification.data);
        }
    }

    async admitSelf(): Promise<void> {
        // Set with ana offset of 5 seconds
        let lastFetch = new Date((new Date()).getTime() - 5000);
        this.selfAdmissionAwaiter = setInterval(async () => {
            const before = new Date();
            await this.admitSelfHandler(lastFetch);
            lastFetch = before;
        }, 3000);
    } 

    async generateLink(): Promise<string> {
        // Invoke the private API
        console.log('invoking private api');
        const result = await Server().privateApi.facetime.generateLink(this.callUuid);
        console.log(result);
        if (!result?.data?.url) {
            throw new Error("Failed to generate FaceTime link!");
        }

        // Set the url
        this.url = result.data.url;
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

    static async fromGeneratedLink(callUuid: string = null): Promise<FaceTimeSession> {
        const session = new FaceTimeSession({ callUuid });
        console.log('Generating link');
        await session.generateLink();
        console.log(session.url)
        return session;
    }
}
