/* eslint-disable prefer-const */
import { RouterContext } from "koa-router";
import { Next } from "koa";
import type { File } from "formidable";

import { Server } from "@server/index";
import { getMessageResponse, Message } from "@server/databases/imessage/entity/Message";
import { DBMessageParams } from "@server/databases/imessage/types";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { ActionHandler } from "@server/helpers/actions";
import { MessageInterface } from "../interfaces/messageInterface";
import { Success } from "../responses/success";
import { BadRequest, IMessageError, NotFound } from "../responses/errors";

export class MessageRouter {
    static async sentCount(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount(null, null, true);
        return new Success(ctx, { data: { total } }).send();
    }

    static async count(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount();
        return new Success(ctx, { data: { total } }).send();
    }

    static async find(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const withQuery = ((ctx.request.query.with ?? "") as string)
            .toLowerCase()
            .split(",")
            .map(e => e.trim());
        const withChats = withQuery.includes("chats") || withQuery.includes("chat");
        const withParticipants = withQuery.includes("chats.participants") || withQuery.includes("chat.participants");
        const withAttachments = withQuery.includes("attachments") || withQuery.includes("attachment");

        // Fetch the info for the message by GUID
        const message = await Server().iMessageRepo.getMessage(guid, withChats, withAttachments);
        if (!message) throw new NotFound({ error: "Message does not exist!" });

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

        return new Success(ctx, { data: await getMessageResponse(message) }).send();
    }

    static async query(ctx: RouterContext, _: Next) {
        let { chatGuid, with: withQuery, offset, limit, where, sort, after, before } = ctx?.request?.body;

        // Pull out the filters
        withQuery = withQuery.filter((e: any) => typeof e === "string").map((e: string) => e.toLowerCase().trim());
        const withChats = withQuery.includes("chat") || withQuery.includes("chats");
        const withAttachments = withQuery.includes("attachment") || withQuery.includes("attachments");
        const withHandle = withQuery.includes("handle");
        const withSMS = withQuery.includes("sms");
        const withChatParticipants =
            withQuery.includes("chat.participants") || withQuery.includes("chats.participants");

        // We don't need to worry about it not being a number because
        // the validator checks for that. It also checks for min values.
        offset = offset ? Number.parseInt(offset, 10) : 0;
        limit = limit ? Number.parseInt(limit, 10) : 100;

        if (chatGuid) {
            const chats = await Server().iMessageRepo.getChats({ chatGuid, withSMS: true });
            if (!chats || chats.length === 0)
                return new Success(ctx, {
                    message: `No chat found with GUID: ${chatGuid}`,
                    data: []
                });
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
        if (where && where.length > 0) opts.where = where;

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
        const data = [];
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
            data.push(msgRes);
        }

        // Build metadata to return
        const metadata = { offset, limit };
        return new Success(ctx, { data, message: "Successfully fetched messages!", metadata }).send();
    }

    static async sendText(ctx: RouterContext, _: Next) {
        let { tempGuid, message, method, chatGuid, effectId, subject, selectedMessageGuid } = ctx?.request?.body;

        // Default the method to AppleScript
        method = method ?? "apple-script";

        // If we have an effectId or subject, let's imply we want to use
        // the Private API
        if (effectId || subject || selectedMessageGuid) {
            method = "private-api";
        }

        // Add to send cache
        Server().httpService.sendCache.add(tempGuid);

        try {
            // Send the message
            const sentMessage = await MessageInterface.sendMessageSync(
                chatGuid,
                message,
                method,
                subject,
                effectId,
                selectedMessageGuid,
                tempGuid
            );

            // Convert to an API response
            const data = await getMessageResponse(sentMessage);
            return new Success(ctx, { message: "Message sent!", data }).send();
        } catch (ex: any) {
            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Message Send Error",
                    data: await getMessageResponse(ex),
                    error: "Failed to send message! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Message Send Error", error: ex?.message ?? ex.toString() });
            }
        }
    }

    static async sendAttachment(ctx: RouterContext, _: Next) {
        const { files } = ctx.request;
        const { tempGuid, chatGuid, name } = ctx.request?.body;
        const attachment = files?.attachment as File;

        // Add to send cache
        Server().httpService.sendCache.add(tempGuid);

        // Send the attachment
        try {
            const sentMessage: Message = await MessageInterface.sendAttachmentSync(
                chatGuid, attachment.path, name, tempGuid);

            // Convert to an API response
            const data = await getMessageResponse(sentMessage);
            return new Success(ctx, { message: "Attachment sent!", data }).send();
        } catch (ex: any) {
            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Attachment Send Error",
                    data: await getMessageResponse(ex),
                    error: "Failed to send attachment! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Attachment Send Error", error: ex?.message ?? ex.toString() });
            }
        }
    }

    static async react(ctx: RouterContext, _: Next) {
        const { chatGuid, selectedMessageGuid, reaction } = ctx?.request?.body;

        // Fetch the message we are reacting to
        const message = await Server().iMessageRepo.getMessage(selectedMessageGuid, false, true);
        if (!message) throw new BadRequest({ error: "Selected message does not exist!" });

        // Send the reaction
        try {
            const sentMessage = await MessageInterface.sendReaction(chatGuid, message, reaction);
            return new Success(ctx, { message: "Reaction sent!", data: await getMessageResponse(sentMessage) }).send();
        } catch (ex: any) {
            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Reaction Send Error",
                    data: await getMessageResponse(ex),
                    error: "Failed to send reaction! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Reaction Send Error", error: ex?.message ?? ex.toString() });
            }
        }
    }
}
