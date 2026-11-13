import { IMessagePollResult, IMessagePollType, IMessagePoller } from ".";
import { Message } from "../entity/Message";
import { isEmpty } from "@server/helpers/utils";
import { Server } from "@server";
import { MESSAGE_FAST_LOOKBACK_MS, MESSAGE_RECONCILE_INTERVAL_MS, MESSAGE_RECONCILE_LOOKBACK_MS } from "./constants";

export class MessagePoller extends IMessagePoller {
    tag = "MessagePoller";

    type = IMessagePollType.MESSAGE;

    unsentIds: number[] = [];

    // Apple only allows edits within ~15 minutes and unsends within ~2 minutes of sending,
    // so a much smaller lookback than a full week is enough to catch those on every tick.
    static readonly FAST_LOOKBACK_MS = MESSAGE_FAST_LOOKBACK_MS;

    // Periodically we still widen the lookback to a full week so we don't permanently miss
    // things that can legitimately change well outside the fast window (e.g. a read receipt
    // or notification flag on an older message).
    static readonly RECONCILE_LOOKBACK_MS = MESSAGE_RECONCILE_LOOKBACK_MS;

    static readonly RECONCILE_INTERVAL_MS = MESSAGE_RECONCILE_INTERVAL_MS;

    lastReconcileAt = 0;

    async poll(after: Date): Promise<IMessagePollResult[]> {
        let results: IMessagePollResult[] = [];

        // Lookback using date created because date created has a SQLite index on it, while
        // the other dates don't. Because of this, searching is much faster. We can do the
        // filtering after the query.
        const now = Date.now();
        const dueForReconcile = now - this.lastReconcileAt >= MessagePoller.RECONCILE_INTERVAL_MS;
        const lookbackMs = dueForReconcile ? MessagePoller.RECONCILE_LOOKBACK_MS : MessagePoller.FAST_LOOKBACK_MS;
        if (dueForReconcile) this.lastReconcileAt = now;

        const afterLookback = new Date(after.getTime() - lookbackMs);

        // let start = new Date();
        // Skip the attachment join here -- the filtering below never looks at attachments,
        // and joining them over this lookback window is the most expensive part of this
        // query. We only fetch attachments for the small set of rows that actually changed.
        const [search, __] = await this.repo.getMessages({
            after: afterLookback,
            withChats: true,
            withAttachments: false,
            orderBy: "message.dateCreated"
        });

        // Filter out messages that aren't within our actual range.
        // Do this here instead of in SQLite to save on performance
        const afterTime = after.getTime();
        let entries = search.filter(e => (
            (e.dateCreated?.getTime() ?? 0) >= afterTime ||
            // Date delivered only matters if it's from you
            (e.isFromMe && (e.dateDelivered?.getTime() ?? 0)) >= afterTime ||
            (e.isFromMe && !e.dateDelivered && e.isDelivered) ||
            // Date read only matters if it's from you and it's not a group chat
            (e.isFromMe && !e.chats[0].isGroup && (e.dateRead?.getTime() ?? 0)) >= afterTime ||
            // Date edited can be from anyone (should include edits & unsends)
            (e.dateEdited?.getTime() ?? 0) >= afterTime ||
            // Date retracted can be from anyone, but Apple doesn't even use this field.
            // We still want to be thorough and check it.
            // isEmpty is what's actually used by Apple to determine if it's retracted.
            // (in addition to dateEdited)
            (e.dateRetracted?.getTime() ?? 0) >= afterTime ||
            // If there are retracted parts, it's unsent
            e.hasUnsentParts ||
            // If didNotifyRecipient changed (from false to true)
            (e.didNotifyRecipient ?? false)
        ));

        // Hydrate the (small) set of changed entries with their attachments, since downstream
        // consumers (sockets, webhooks) need the full message payload.
        if (entries.length > 0) {
            const [hydrated] = await this.repo.getMessages({
                withChats: true,
                withAttachments: true,
                limit: entries.length,
                where: [
                    {
                        statement: `message.ROWID in (${entries.map(e => e.ROWID).join(", ")})`,
                        args: null
                    }
                ]
            });

            const hydratedByRowId = new Map(hydrated.map(e => [e.ROWID, e]));
            entries = entries.map(e => hydratedByRowId.get(e.ROWID) ?? e);
        }

        // Handle group changes
        const groupChangeEntries = entries.filter(e => isEmpty(e.text) && [1, 2, 3].includes(e.itemType));
        results = results.concat(this.handleGroupChanges(groupChangeEntries));

        // Fetch previously unsent messages
        if (this.unsentIds.length > 0) {
            const [previouslyUnsentEntries, _] = await this.repo.getMessages({
                withChats: true,
                where: [
                    {
                        statement: `message.ROWID in (${this.unsentIds.join(", ")})`,
                        args: null
                    }
                ]
            });
            results = results.concat(await this.handlePreviouslyUnsent(previouslyUnsentEntries));
        }

        // Handle new unsent messages
        const unsent = entries.filter(e => !e.isSent);
        for (const entry of unsent) {
            if (!this.unsentIds.includes(entry.ROWID)) {
                this.unsentIds.push(entry.ROWID);
            }
        }

        // Handle the new/updated message
        for (const entry of entries) {
            const event = this.processMessageEvent(entry);
            if (!event) continue;

            // Resolve the promise for sent messages from a client
            if (entry.isFromMe) {
                Server().messageManager.resolve(entry);
            }

            // Emit the event
            results.push({ eventType: event, data: entry });
        }

        // Sort results ascending order by date created so that older messages are processed first
        results.sort((a, b) => a.data.dateCreated.getTime() - b.data.dateCreated.getTime());

        return results;
    }

    handleGroupChanges(entries: Message[]): IMessagePollResult[] {
        const results: IMessagePollResult[] = [];

        for (const entry of entries) {
            const identifier = `group-change-${entry.ROWID}`;

            // Skip over any that we've finished
            if (this.cache.messageEvents.find(identifier)) continue;

            // Add to cache
            this.cache.messageEvents.add(identifier);

            // Send the built message object
            if (entry.itemType === 1 && entry.groupActionType === 0) {
                results.push({ eventType: "participant-added", data: entry });
            } else if (entry.itemType === 1 && entry.groupActionType === 1) {
                results.push({ eventType: "participant-removed", data: entry });
            } else if (entry.itemType === 2) {
                results.push({ eventType: "name-change", data: entry });
            } else if (entry.itemType === 3 && entry.groupActionType === 0) {
                results.push({ eventType: "participant-left", data: entry });
            } else if (entry.itemType === 3 && entry.groupActionType === 1) {
                results.push({ eventType: "group-icon-changed", data: entry });
            } else if (entry.itemType === 3 && entry.groupActionType === 2) {
                results.push({ eventType: "group-icon-removed", data: entry });
            } else {
                console.warn(`Unhandled message item type: [${entry.itemType}]`);
            }
        }

        return results;
    }

    async handlePreviouslyUnsent(entries: Message[]): Promise<IMessagePollResult[]> {
        const results: IMessagePollResult[] = [];

        const sent = entries.filter(item => item.isSent && (item?.error ?? 0) === 0);
        const errored = entries.filter(item => (item?.error ?? 0) > 0);
        const unsent = entries.filter(item => !item.isSent && (item?.error ?? 0) === 0);

        // Update the global list containing messages that are still unsent
        this.unsentIds = unsent.map(e => e.ROWID);

        // Gather the new sent messages
        for (const entry of sent) {
            const event = this.processMessageEvent(entry);
            if (!event) continue;

            // Resolve the promise for sent messages from a client
            Server().messageManager.resolve(entry);

            // Emit it as normal entry
            results.push({ eventType: event, data: entry });
        }

        // Gather the errored messages
        for (const entry of errored) {
            const event = this.processMessageEvent(entry);
            if (!event) continue;

            const success = await Server().messageManager.reject("message-send-error", entry);
            Server().log(
                `Errored Msg -> ${entry.guid} -> ${entry.contentString()} -> ${success} (Code: ${entry.error})`,
                "debug"
            );

            // Emit it as normal error
            if (!success) {
                Server().log(
                    `Message Manager Match Failed -> Promises: ${Server().messageManager.promises.length}`,
                    "debug"
                );
                results.push({ eventType: "message-send-error", data: entry });
            }
        }

        return results;
    }
}
