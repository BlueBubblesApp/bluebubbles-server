import { FaceTimeSession, FaceTimeSessionStatus } from "./FaceTimeSession";


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
        return this.sessions.find(session => (session.callUuid ?? '').toLowerCase() === callUuid.toLowerCase());
    }

    addSession(session: FaceTimeSession): boolean {
        const existingSession = session?.callUuid ? this.findSession(session.callUuid) : null;
        const isNew = !existingSession;

        // If the session exists, invalidate the old one and replace it with the new one.
        if (existingSession) {
            existingSession.update(session);
        } else {
            this.sessions.push(session);
        }
        
        this.purgeOldSessions();
        return isNew;
    }

    invalidateSession(callUuid: string) {
        const session = this.findSession(callUuid);
        if (session) {
            session.invalidate();
        }
    }

    clearSessions() {
        for (const session of this.sessions) {
            session.invalidate();
        }

        this.sessions = [];
    }

    purgeOldSessions() {
        // Purge sessions older than 3 hours & invalidated
        const now = new Date().getTime();
        this.sessions = this.sessions.filter(session => {
            return (
                session.status !== FaceTimeSessionStatus.DISCONNECTED ||
                now - session.createdAt.getTime() < 1000 * 60 * 60 * 3
            );
        });
    }
}
