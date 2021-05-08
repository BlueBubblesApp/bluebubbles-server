import type { EventCache } from "@server/helpers/eventCache";

import { ChangeListener } from "@server/interface/changeListener";
import { getCacheName } from "../helpers/utils";

import type DefaultMessagesApi from "../index";
import type { Message } from "../entity/Message";
import { ApiEvent } from "../../types";

export class IncomingMessageListener extends ChangeListener {
    app: DefaultMessagesApi;

    constructor(app: DefaultMessagesApi, cache: EventCache, pollFrequency: number) {
        super({ cache, pollFrequency });

        this.app = app;

        // Start the listener
        this.start();
    }

    async getEntries(after: Date, before: Date): Promise<void> {
        // Offset 15 seconds to account for the "Apple" delay
        const offsetDate = new Date(after.getTime() - 15000);
        const query = [
            {
                statement: "message.is_from_me = :fromMe",
                args: { fromMe: 0 }
            }
        ];

        // If SMS support isn't enabled, add the iMessage server specifier
        // const smsSupport = Server().db.getConfig("sms_support") as boolean;
        // if (!smsSupport) {
        //     query.push({
        //         statement: "message.service = 'iMessage'",
        //         args: null
        //     });
        // }

        const entries = await this.app.api.getMessages({
            after: offsetDate,
            before,
            withChats: true,
            where: query
        });

        // Emit the new message
        entries.forEach(async (entry: any) => {
            const cacheName = getCacheName(entry);

            // Skip over any that we've finished
            if (this.cache.find(cacheName)) return;

            // Add to cache
            this.cache.add(cacheName);
            super.emit(ApiEvent.NEW_MESSAGE, this.transformEntry(entry));
        });
    }

    // eslint-disable-next-line class-methods-use-this
    transformEntry(entry: Message) {
        return entry;
    }
}
