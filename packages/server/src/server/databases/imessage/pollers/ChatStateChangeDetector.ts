import type { ChatSnapshotEntry } from "../snapshot/ChatStateSnapshot";
import { compareDecimalStrings } from "../snapshot/ChatStateSnapshot";

export type ChatStateChange = { guid: string; read: boolean } | { guid: string; deleted: true };

type TrackedState = {
    read: boolean;
    messageCount: number;
    readPointer: string;
};

/** Diffs consecutive Apple-side snapshots without replaying historical state. */
export class ChatStateChangeDetector {
    private readonly states = new Map<string, TrackedState>();

    private toTracked(entry: ChatSnapshotEntry): TrackedState {
        return {
            read: entry.read,
            messageCount: entry.messageCount,
            readPointer: entry.readPointer
        };
    }

    seed(entries: ChatSnapshotEntry[]): void {
        this.states.clear();
        for (const entry of entries) this.states.set(entry.guid, this.toTracked(entry));
    }

    observe(entries: ChatSnapshotEntry[]): ChatStateChange[] {
        const changes: ChatStateChange[] = [];
        const current = new Map<string, TrackedState>();
        for (const entry of entries) current.set(entry.guid, this.toTracked(entry));

        for (const [guid, previous] of this.states) {
            if (previous.messageCount <= 0) continue;

            const next = current.get(guid);
            if (!next || next.messageCount === 0) {
                changes.push({ guid, deleted: true });
                continue;
            }

            const pointerChange = compareDecimalStrings(next.readPointer, previous.readPointer);
            if (pointerChange < 0 || (previous.read && !next.read)) {
                changes.push({ guid, read: false });
                continue;
            }
            if ((pointerChange > 0 && next.read) || (!previous.read && next.read)) {
                changes.push({ guid, read: true });
            }
        }

        this.states.clear();
        for (const [guid, state] of current) this.states.set(guid, state);
        return changes;
    }
}
