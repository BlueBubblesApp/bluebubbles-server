import { ChangeListener } from "@server/interface/changeListener";

import type DefaultMessagesApi from "../index";
import type { Message } from "../entity/Message";
import { ApiEvent } from "../../types";

export class GroupChangeListener extends ChangeListener {
    app: DefaultMessagesApi;

    frequencyMs: number;

    constructor(app: DefaultMessagesApi, pollFrequency: number) {
        super({ pollFrequency });

        this.app = app;
        this.frequencyMs = pollFrequency;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date, before: Date): Promise<void> {
        const offsetDate = new Date(after.getTime() - 5000);
        const entries = await this.app.api.getMessages({
            after: offsetDate,
            before,
            where: [
                {
                    statement: "message.text IS NULL",
                    args: null
                },
                {
                    statement: "message.item_type IN (1, 2, 3)",
                    args: null
                }
            ]
        });

        // Emit the new message
        let emitCount = 0;
        for (const entry of entries) {
            // Skip over any that we've finished
            if (this.cache.find(entry.ROWID.toString())) return;

            // Add to cache
            this.cache.add(entry.ROWID.toString());

            // Send the built message object
            if (entry.itemType === 1 && entry.groupActionType === 0) {
                super.emit(ApiEvent.GROUP_PARTICIPANT_ADDED, this.transformEntry(entry));
            } else if (entry.itemType === 1 && entry.groupActionType === 1) {
                super.emit(ApiEvent.GROUP_PARTICIPANT_REMOVED, this.transformEntry(entry));
            } else if (entry.itemType === 2) {
                super.emit(ApiEvent.GROUP_NAME_CHANGE, this.transformEntry(entry));
            } else if (entry.itemType === 3) {
                super.emit(ApiEvent.GROUP_PARTICIPANT_LEFT, this.transformEntry(entry));
            } else {
                console.warn(`Unhandled message item type: [${entry.itemType}]`);
                continue;
            }

            emitCount += 1;
        }

        if (emitCount > 0) this.app.logger.debug(`Emitted ${emitCount} group message events`);
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
