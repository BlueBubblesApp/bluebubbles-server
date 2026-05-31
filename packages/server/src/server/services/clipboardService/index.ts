import { clipboard } from "electron";
import { Loggable } from "@server/lib/logging/Loggable";
import { Server } from "@server";
import { CLIPBOARD_SYNC } from "@server/events";

export class ClipboardService extends Loggable {
    tag = "ClipboardService";

    private pollInterval: NodeJS.Timeout | null = null;
    private lastKnown = "";
    private lastWritten = "";
    private readonly POLL_MS = 500;

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

    // Called by socket handler when a client sends clipboard content.
    // Updates lastWritten so the next poll doesn't echo it back.
    writeFromClient(text: string) {
        this.lastWritten = text;
        this.lastKnown = text;
        clipboard.writeText(text);
    }

    private poll() {
        const current = clipboard.readText();
        if (!current || current === this.lastKnown) return;
        this.lastKnown = current;
        // Suppress echo of content we just wrote from a client
        if (current === this.lastWritten) return;
        Server().emitMessage(CLIPBOARD_SYNC, { content: current }, "normal", false);
    }
}
