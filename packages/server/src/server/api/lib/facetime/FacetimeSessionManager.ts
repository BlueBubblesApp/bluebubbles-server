import { FaceTimeSession } from "./FaceTimeSession";


let instance: FaceTimeSessionManagerSingleton | null = null;
export const FaceTimeSessionManager = () => {
    if (!instance) {
        instance = new FaceTimeSessionManagerSingleton();
    }

    return instance;
}


class FaceTimeSessionManagerSingleton {
    sessions: FaceTimeSession[] = [];

    findSession(callUuid: string): FaceTimeSession {
        return this.sessions.find(session => session.callUuid.toLowerCase() === callUuid.toLowerCase());
    }

    addSession(session: FaceTimeSession) {
        const existingSession = this.findSession(session.callUuid);

        // If the session exists, invalidate the old one and replace it with the new one.
        if (existingSession) {
            existingSession.invalidate();
            this.sessions.splice(this.sessions.indexOf(existingSession), 1);
        }

        this.sessions.push(session);
    }

    invalidateSession(callUuid: string) {
        const session = this.findSession(callUuid);
        if (session) {
            session.invalidate();
            this.sessions.splice(this.sessions.indexOf(session), 1);
        }
    }

    clearSessions() {
        for (const session of this.sessions) {
            session.invalidate();
        }

        this.sessions = [];
    }
}
