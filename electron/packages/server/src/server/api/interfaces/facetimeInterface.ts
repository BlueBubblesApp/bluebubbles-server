import { Server } from "@server";
import { FaceTimeSession } from "../lib/facetime/FaceTimeSession";
import { isMinMonterey } from "@server/env";
import { checkPrivateApiStatus } from "@server/helpers/utils";

/**
 * An interface to interact with Facetime
 */
export class FaceTimeInterface {
    static async create(): Promise<string> {
        checkPrivateApiStatus();
        if (!isMinMonterey) throw new Error("Creating FaceTime calls is only available on macOS Big Sur and newer!");
        const session = await FaceTimeSession.fromGeneratedLink(null);
        session.admitAndLeave();
        return session.url;
    }

    static async answer(callUuid: string): Promise<string> {
        checkPrivateApiStatus();
        if (!isMinMonterey) throw new Error("Answering FaceTime calls is only available on macOS Big Sur and newer!");
        return await FaceTimeInterface.answerAndWaitForLink(callUuid);
    }

    static async leave(callUuid: string): Promise<void> {
        checkPrivateApiStatus();
        if (!isMinMonterey) throw new Error("Leaving FaceTime calls is only available on macOS Big Sur and newer!");
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
