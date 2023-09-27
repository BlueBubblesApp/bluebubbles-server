import { Server } from "@server";
import { FaceTimeSession } from "../lib/facetime/FaceTimeSession";

/**
 * An interface to interact with Facetime
 */
export class FaceTimeInterface {
    static async answer(callUuid: string): Promise<string> {
        return await FaceTimeInterface.answerAndWaitForLink(callUuid);
    }

    static async leave(callUuid: string): Promise<void> {
        await Server().privateApi.facetime.leaveCall(callUuid);
    }

    private static async answerAndWaitForLink(callUuid: string): Promise<string> {
        return await new Promise((resolve, reject) => {
            try {
                FaceTimeSession.answerIncomingCall(callUuid, (link: string) => {
                    resolve(link);
                });
            } catch (ex) {
                reject(ex);
            }
        });
    }
}
