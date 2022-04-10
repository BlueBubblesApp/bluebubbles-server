import { safeTrim } from "@server/helpers/utils";
import { Server } from "@server";
import { createTextChangeRange } from "typescript";

export class ServerInterface {
    static async getDatabaseTotals({ only = ["handle", "message", "chat", "attachment"] }: { only?: string[] } = {}) {
        // If an element ends with an 's', remove it.
        // Also, make them all lower-cased
        const items = only.map(e =>
            e.toLowerCase().substring(e.length - 1, e.length) === "s"
                ? safeTrim(e.substring(0, e.length - 1).toLowerCase())
                : safeTrim(e.toLowerCase())
        );

        const results: any = {};
        if (items.includes("handle")) {
            results.handles = await Server().iMessageRepo.getHandleCount();
        }
        if (items.includes("message")) {
            results.messages = await Server().iMessageRepo.getMessageCount();
        }
        if (items.includes("chat")) {
            results.chats = await Server().iMessageRepo.getChatCount();
        }
        if (items.includes("attachment")) {
            results.attachments = await Server().iMessageRepo.getAttachmentCount();
        }

        return results;
    }

    static async getMediaTotals({ only = ["image", "video", "location", "other"] }: { only?: string[] } = {}) {
        // If an element ends with an 's', remove it.
        // Also, make them all lower-cased
        const items = only.map(e =>
            e.toLowerCase().substring(e.length - 1, e.length) === "s"
                ? safeTrim(e.substring(0, e.length - 1).toLowerCase())
                : safeTrim(e.toLowerCase())
        );

        const results: any = {};
        if (items.includes("image")) {
            results.images = (await Server().iMessageRepo.getMediaCounts({ mediaType: "image" }))[0].media_count;
        }
        if (items.includes("video")) {
            results.videos = (await Server().iMessageRepo.getMediaCounts({ mediaType: "video" }))[0].media_count;
        }
        if (items.includes("location")) {
            results.locations = (await Server().iMessageRepo.getMediaCounts({ mediaType: "location" }))[0].media_count;
        }

        return results;
    }

    static async getMediaTotalsByChat({ only = ["image", "video", "location"] }: { only?: string[] } = {}) {
        // If an element ends with an 's', remove it.
        // Also, make them all lower-cased
        const items = only.map(e =>
            e.toLowerCase().substring(e.length - 1, e.length) === "s"
                ? safeTrim(e.substring(0, e.length - 1).toLowerCase())
                : safeTrim(e.toLowerCase())
        );

        const results: any = {};

        // Helper for adding counts to the results
        const addToResults = (result: any[], identifier: string) => {
            for (const i of result) {
                const totals: any = {};
                for (const cat of items) {
                    totals[`${cat}s`] = results[i.chat_guid]?.totals[`${cat}s`] ?? 0;
                }

                if (!Object.keys(results).includes(i.chat_guid)) {
                    results[i.chat_guid] = {
                        chatGuid: i.chat_guid,
                        groupName: i.group_name,
                        totals
                    };
                }

                results[i.chat_guid].totals[identifier] = i.media_count;
            }
        };

        if (items.includes("image")) {
            const res = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "image" });
            addToResults(res, "images");
        }
        if (items.includes("video")) {
            const res = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "video" });
            addToResults(res, "videos");
        }
        if (items.includes("location")) {
            const res = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "location" });
            addToResults(res, "locations");
        }

        return Object.values(results);
    }
}
