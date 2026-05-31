import { clipboard } from "electron";
import { Loggable } from "@server/lib/logging/Loggable";
import { Server } from "@server";
import { CLIPBOARD_SYNC } from "@server/events";

interface ClipboardItem {
    text: string;
    timestamp: number;
}

export class ClipboardService extends Loggable {
    tag = "ClipboardService";

    private pollInterval: NodeJS.Timeout | null = null;
    private lastKnown = "";
    private lastWritten = "";
    private readonly POLL_MS = 500;
    private history: ClipboardItem[] = [];
    private readonly MAX_HISTORY = 20;

    start() {
        if (this.pollInterval) return;
        this.lastKnown = clipboard.readText();
        this.pollInterval = setInterval(() => this.poll(), this.POLL_MS);
        this.log.info("Clipboard sync service started");
    }

    stop() {
        if (!this.pollInterval) return;
        clearInterval(this.pollInterval);
        this.pollInterval = null;
        this.log.info("Clipboard sync service stopped");
    }

    getHistory(): ClipboardItem[] {
        return this.history;
    }

    // Called by socket handler when a client sends clipboard content.
    // Updates lastWritten so the next poll doesn't echo it back.
    writeFromClient(text: string) {
        this.lastWritten = text;
        this.lastKnown = text;
        clipboard.writeText(text);
        this.addToHistory(text);
    }

    private poll() {
        const current = clipboard.readText();
        if (!current || current === this.lastKnown) return;
        this.lastKnown = current;
        // Suppress echo of content we just wrote from a client
        if (current === this.lastWritten) return;
        this.addToHistory(current);
        Server().emitMessage(CLIPBOARD_SYNC, { content: current }, "normal", false);
    }

    private addToHistory(text: string) {
        if (this.history.length > 0 && this.history[0].text === text) return;
        this.history.unshift({ text, timestamp: Date.now() });
        if (this.history.length > this.MAX_HISTORY) {
            this.history.pop();
        }
    }
}
