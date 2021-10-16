import { RouterContext } from "koa-router";
import { Next } from "koa";
import type { File } from "formidable";

import { Server } from "@server/index";
import {
    createBadRequestResponse,
    createNotFoundResponse,
    createServerErrorResponse,
    createSuccessResponse
} from "@server/helpers/responses";
import { ErrorTypes } from "@server/types";
import { getMessageResponse, Message } from "@server/databases/imessage/entity/Message";
import { DBMessageParams } from "@server/databases/imessage/types";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { ActionHandler } from "@server/helpers/actions";
import { parseNumber } from "../../../helpers";
import { MessageInterface } from "../interfaces/messageInterface";

export class MessageRouter {
    static async sentCount(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount(null, null, true);
        ctx.body = createSuccessResponse({ total });
    }

    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount();
        ctx.body = createSuccessResponse({ total });
    }

    static async find(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const withQuery = ((ctx.request.query.with ?? "") as string)
            .toLowerCase()
            .split(",")
            .map(e => e.trim());
        const withChats = withQuery.includes("chats") || withQuery.includes("chat");
        const withParticipants = withQuery.includes("chats.participants") || withQuery.includes("chat.participants");

        // Fetch the info for the message by GUID
        const message = await Server().iMessageRepo.getMessage(guid, withChats);
        if (!message) {
            ctx.status = 404;
            ctx.body = createNotFoundResponse("Message does not exist!");
            return;
        }

        // If we want participants of the chat, fetch them
        if (withParticipants) {
            for (const i of message.chats ?? []) {
                const chats = await Server().iMessageRepo.getChats({
                    chatGuid: i.guid,
                    withParticipants,
                    withLastMessage: false,
                    withSMS: true,
                    withArchived: true
                });

                if (!chats || chats.length === 0) continue;
                i.participants = chats[0].participants;
            }
        }

        ctx.body = createSuccessResponse(await getMessageResponse(message));
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the filters
        const withQuery = (body?.with ?? [])
            .filter((e: any) => typeof e === "string")
            .map((e: string) => e.toLowerCase().trim());
        const withChats = withQuery.includes("chat") || withQuery.includes("chats");
        const withAttachments = withQuery.includes("attachment") || withQuery.includes("attachments");
        const withHandle = withQuery.includes("handle");
        const withSMS = withQuery.includes("sms");
        const withChatParticipants =
            withQuery.includes("chat.participants") || withQuery.includes("chats.participants");
        const where = (body?.where ?? []).filter((e: any) => e.statement && e.args);
        const sort = ["DESC", "ASC"].includes((body?.sort ?? "").toLowerCase()) ? body?.sort : "DESC";
        const after = body?.after;
        const before = body?.before;
        const chatGuid = body?.chatGuid;

        // Pull the pagination params and make sure they are correct
        let offset = parseNumber(body?.offset as string) ?? 0;
        let limit = parseNumber(body?.limit as string) ?? 100;
        if (offset < 0) offset = 0;
        if (limit < 0 || limit > 1000) limit = 1000;

        if (chatGuid) {
            const chats = await Server().iMessageRepo.getChats({ chatGuid, withSMS: true });
            if (!chats || chats.length === 0) {
                ctx.body = createSuccessResponse([]);
                return;
            }
        }

        const opts: DBMessageParams = {
            chatGuid,
            withChats,
            withAttachments,
            withHandle,
            withSMS,
            offset,
            limit,
            sort,
            before,
            after
        };

        // Since we have a default value for `where`, we have to set it conditionally
        if (where && where.length > 0) {
            opts.where = where;
        }

        // Fetch the info for the message by GUID
        const messages = await Server().iMessageRepo.getMessages(opts);

        // Handle fetching the chat participants with the messages (if requested)
        const chatCache: { [key: string]: Handle[] } = {};
        if (withChats && withChatParticipants) {
            const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
            for (const i of chats) {
                chatCache[i.guid] = i.participants;
            }
        }

        // Do you want the blurhash? Default to false
        const results = [];
        for (const msg of messages) {
            // Insert in the participants from the cache
            if (withChatParticipants) {
                for (const chat of msg.chats) {
                    if (Object.keys(chatCache).includes(chat.guid)) {
                        chat.participants = chatCache[chat.guid];
                    }
                }
            }

            const msgRes = await getMessageResponse(msg);
            results.push(msgRes);
        }

        // Build metadata to return
        const metadata = {
            offset,
            limit
        };

        ctx.body = createSuccessResponse(results, null, metadata);
    }

    static async sendText(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        const tempGuid = body?.tempGuid;
        const chatGuid = body?.guid;
        const message = body?.message;
        let method = body?.method ?? "apple-script";
        const effectId = body?.effectId;
        const subject = body?.subject;
        const selectedMessageGuid = body?.selectedMessageGuid;

        // If we have an effectId or subject, let's imply we want to use
        // the Private API
        if (effectId || subject || selectedMessageGuid) {
            method = "private-api";
        }

        // Make sure a chat GUID is provided
        if (!chatGuid) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Chat GUID not provided!");
            return;
        }

        // Make sure we have a temp GUID, for matching
        if (!tempGuid || tempGuid.length === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Temporary GUID not provided!");
            return;
        }

        // Make sure the message isn't already in the queue
        if (Server().httpService.sendCache.find(tempGuid)) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Message is already queued to be sent!");
            return;
        }

        // Add to send cache
        Server().httpService.sendCache.add(tempGuid);

        try {
            // Send the message
            const sentMessage: Message = await MessageInterface.sendMessageSync(
                chatGuid,
                message,
                method,
                subject,
                effectId,
                selectedMessageGuid
            );
            const res = await getMessageResponse(sentMessage);
            ctx.body = createSuccessResponse(res, "Message sent!");
        } catch (ex: any) {
            ctx.status = 500;
            if (ex instanceof Message) {
                ctx.body = createServerErrorResponse(
                    "Message Send Error",
                    ErrorTypes.IMESSAGE_ERROR,
                    "Failed to send message! See attached message error code.",
                    await getMessageResponse(ex)
                );
            } else {
                Server().log(`Message Send Error: ${ex?.message || ex.toString()}`);
                ctx.body = createServerErrorResponse(ex?.message || ex.toString());
            }
        }
    }

    static async sendAttachment(ctx: RouterContext, _: Next) {
        const { body, files } = ctx.request;

        const tempGuid = body?.tempGuid;
        const chatGuid = body?.guid;
        const name = body?.name;

        // Make sure a chat GUID is provided
        if (!chatGuid) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Chat GUID not provided!");
            return;
        }

        // Make sure we have a temp GUID, for matching
        if (!tempGuid || tempGuid.length === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Temporary GUID not provided!");
            return;
        }

        // Make sure the message isn't already in the queue
        if (Server().httpService.sendCache.find(tempGuid)) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Message is already queued to be sent!");
            return;
        }

        // Make sure the message isn't already in the queue
        if (!name || name.length === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Attachment file name not provided!");
            return;
        }

        // Make sure the message isn't already in the queue
        const attachment = files?.attachment as File;
        if (!attachment || attachment.size === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Attachment not provided or was empty!");
            return;
        }

        // Add to send cache
        Server().httpService.sendCache.add(tempGuid);

        // Send the attachment
        try {
            const sentMessage: Message = await ActionHandler.sendAttachmentSync(chatGuid, attachment.path, name);
            const res = await getMessageResponse(sentMessage);
            ctx.body = createSuccessResponse(res, "Attachment sent!");
        } catch (ex: any) {
            ctx.status = 500;
            if (ex instanceof Message) {
                ctx.body = createServerErrorResponse(
                    "Attachment Send Error",
                    ErrorTypes.IMESSAGE_ERROR,
                    "Failed to send attachment! See attached message error code.",
                    await getMessageResponse(ex)
                );
            } else {
                Server().log(`Attachment Send Error: ${ex?.message || ex.toString()}`);
                ctx.body = createServerErrorResponse(ex?.message || ex.toString());
            }
        }
    }

    static async react(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the required fields
        const chatGuid = body?.chatGuid;
        const selectedMessageText = body?.selectedMessageText;
        const selectedMessageGuid = body?.selectedMessageGuid;
        const reaction = (body?.reaction ?? "").toLowerCase();

        // Make sure we have a chat GUID
        if (!chatGuid || chatGuid.length === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Chat GUID not provided!");
            return;
        }

        // Make sure we have a selected message text
        if (!selectedMessageText || selectedMessageText.length === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Selected Message Text not provided!");
            return;
        }

        // Make sure we have a selected message GUID
        if (!selectedMessageGuid || selectedMessageGuid.length === 0) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse("Selected Message GUID not provided!");
            return;
        }

        // Make sure we have a reaction
        if (!reaction || !MessageInterface.possibleReactions.includes(reaction)) {
            ctx.status = 400;
            ctx.body = createBadRequestResponse(
                `Reaction was invalid or not provided! Must be one of: ${MessageInterface.possibleReactions.join(", ")}`
            );
            return;
        }

        // Send the reaction
        try {
            const sentMessage = await MessageInterface.sendReaction(
                chatGuid,
                selectedMessageGuid,
                selectedMessageText,
                reaction
            );
            const res = await getMessageResponse(sentMessage);
            ctx.body = createSuccessResponse(res, "Reaction sent!");
        } catch (ex: any) {
            ctx.status = 400;
            if (ex instanceof Message) {
                ctx.body = createServerErrorResponse(
                    "Reaction Send Error",
                    ErrorTypes.IMESSAGE_ERROR,
                    "Failed to send reaction! See attached message error code.",
                    await getMessageResponse(ex)
                );
            } else {
                Server().log(`Reaction Send Error: ${ex?.message || ex.toString()}`);
                ctx.body = createServerErrorResponse(ex?.message || ex.toString());
            }
        }
    }
}
