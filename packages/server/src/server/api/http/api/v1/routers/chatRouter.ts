import { RouterContext } from "koa-router";
import { Next } from "koa";

import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { DBMessageParams } from "@server/databases/imessage/types";
import { isEmpty, isNotEmpty, isTruthyBool } from "@server/helpers/utils";
import { ChatInterface } from "@server/api/interfaces/chatInterface";
import { MessageSerializer } from "@server/api/serializers/MessageSerializer";
import { arrayHasOne } from "@server/utils/CollectionUtils";

import { FileStream, Success } from "../responses/success";
import { IMessageError, NotFound } from "../responses/errors";
import { parseWithQuery } from "../utils";
import { ChatSerializer } from "@server/api/serializers/ChatSerializer";

export class ChatRouter {
    static async count(ctx: RouterContext, _: Next) {
        const { includeArchived } = ctx?.request.query ?? {};

        // We want to include the archived by default
        // Using != instead of !== because we want to treat null and undefined as equal
        const withArchived = includeArchived != null ? isTruthyBool(includeArchived as string) : true;

        // Get all the chats so we can parse through them for the breakdown
        const [chats, totalCount] = await Server().iMessageRepo.getChats({ withArchived });
        const serviceCounts: { [key: string]: number } = {};
        for (const chat of chats) {
            if (!Object.keys(serviceCounts).includes(chat.serviceName)) {
                serviceCounts[chat.serviceName] = 0;
            }

            serviceCounts[chat.serviceName] += 1;
        }

        const data = { total: totalCount, breakdown: serviceCounts };
        return new Success(ctx, { data }).send();
    }

    static async find(ctx: RouterContext, _: Next) {
        const withQuery = parseWithQuery(ctx?.request?.query?.with);
        const withParticipants = withQuery.includes("participants");
        const withLastMessage = withQuery.includes("lastmessage");

        const [chats, __] = await Server().iMessageRepo.getChats({
            chatGuid: ctx.params.guid,
            withParticipants,
            withArchived: true
        });

        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        const res = await ChatSerializer.serialize({ chat: chats[0] });
        if (withLastMessage) {
            res.lastMessage = await MessageSerializer.serialize({
                message: await Server().iMessageRepo.getChatLastMessage(ctx.params.guid),
                config: {
                    loadChatParticipants: false
                }
            });
        }

        return new Success(ctx, { data: res }).send();
    }

    static async getMessages(ctx: RouterContext, _: Next) {
        const withQuery = parseWithQuery(ctx?.request?.query?.with);
        const withAttachments = arrayHasOne(withQuery, ["attachment", "attachments"]);
        const withAttributedBody = arrayHasOne(withQuery, [
            "message.attributedbody",
            "message.attributed-body",
            "messages.attributedody",
            "messages.attributed-body"
        ]);
        const withMessageSummaryInfo = arrayHasOne(withQuery, [
            "message.messageSummaryInfo",
            "message.message-summary-info",
            "messages.messageSummaryInfo",
            "messages.message-summary-info"
        ]);
        const withPayloadData = arrayHasOne(withQuery, ["message.payloadData", "message.payload-data"]);
        const { sort, before, after, offset, limit } = ctx?.request.query ?? {};

        const [chats, __] = await Server().iMessageRepo.getChats({
            chatGuid: ctx.params.guid,
            withParticipants: false,
            withArchived: true
        });

        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        const opts: DBMessageParams = {
            chatGuid: ctx.params.guid,
            withAttachments,
            offset: offset ? Number.parseInt(offset as string, 10) : 0,
            limit: limit ? Number.parseInt(limit as string, 10) : 100,
            sort: sort as "ASC" | "DESC",
            before: before ? Number.parseInt(before as string, 10) : null,
            after: after ? Number.parseInt(after as string, 10) : null
        };

        // Fetch the info for the message by GUID
        const [messages, totalCount] = await Server().iMessageRepo.getMessages(opts);
        const results = await MessageSerializer.serializeList({
            messages,
            config: {
                loadChatParticipants: false,
                parseAttributedBody: withAttributedBody,
                parseMessageSummary: withMessageSummaryInfo,
                parsePayloadData: withPayloadData
            }
        });

        const metadata = { offset: opts.offset, limit: opts.limit, total: totalCount, count: messages.length };
        return new Success(ctx, { data: results, metadata }).send();
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;

        // Pull out the filters
        const withQuery = parseWithQuery(body?.with);

        const withLastMessage = arrayHasOne(withQuery, ["lastmessage", "last-message"]);
        const guid = body?.guid;
        let sort = body?.sort;
        const { offset, limit } = body;

        // Default to sorting by last message if with last message
        if (withLastMessage && isEmpty(sort)) {
            sort = "lastmessage"
        }

        // Fetch the chats
        const [results, total] = await ChatInterface.get({
            guid,
            withLastMessage,
            offset: offset ? Number.parseInt(offset, 10) : 0,
            limit: limit ? Number.parseInt(limit, 10) : 1000,
            sort
        });

        // Build metadata to return
        const metadata = {
            count: results.length,
            total,
            offset,
            limit
        };

        return new Success(ctx, { data: results, metadata }).send();
    }

    static async update(ctx: RouterContext, _: Next): Promise<void> {
        const { body } = ctx.request;
        const { guid } = ctx.params;
        const displayName = body?.displayName;

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid: guid, withParticipants: true });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        let chat = chats[0];
        const updated = [];
        const errors: string[] = [];
        if (displayName) {
            if (chat.participants.length <= 1) {
                throw new IMessageError({ message: "Cannot rename a non-group chat!", error: "Chat is not a group" });
            }

            try {
                chat = await ChatInterface.setDisplayName(chat, displayName);
                updated.push("displayName");
            } catch (ex: any) {
                errors.push(ex?.message ?? ex);
            }
        }

        if (isNotEmpty(errors)) {
            throw new IMessageError({ message: "Chat update executed with errors!", error: errors.join(", ") });
        }

        const data = await ChatSerializer.serialize({ chat });
        if (isEmpty(updated)) {
            return new Success(ctx, { data, message: "Chat not updated! No update information provided!" }).send();
        }

        return new Success(ctx, {
            message: `Successfully updated the following fields: ${updated.join(", ")}`,
            data
        }).send();
    }

    static async create(ctx: RouterContext, _: Next): Promise<void> {
        const { body } = ctx.request;
        const {
            addresses,
            message,
            method,
            service,
            tempGuid,
            subject,
            effectId,
            attributedBody
        } = body;

        const chat = await ChatInterface.create({
            addresses,
            message,
            method,
            service,
            tempGuid,
            subject,
            effectId,
            attributedBody
        });
        if (!chat) throw new IMessageError({ error: "Failed to create chat!" });

        // Convert the data to an API response
        const data = await ChatSerializer.serialize({
            chat,
            config: {
                includeParticipants: true,
                includeMessages: true
            }
         });

        // Inject the tempGuid back into the messages (if available)
        if (isNotEmpty(tempGuid)) {
            for (const i of data.messages ?? []) {
                i.tempGuid = tempGuid;
            }
        }

        return new Success(ctx, { data, message: "Successfully created chat!" }).send();
    }

    static async addParticipant(ctx: RouterContext, next: Next): Promise<void> {
        await ChatRouter.toggleParticipant(ctx, next, "add");
    }

    static async markRead(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;
        await ChatInterface.markRead(guid);
        return new Success(ctx, { message: "Successfully marked chat as read!" }).send();
    }

    static async markUnread(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;
        await ChatInterface.markUnread(guid);
        return new Success(ctx, { message: "Successfully marked chat as unread!" }).send();
    }

    static async removeParticipant(ctx: RouterContext, next: Next): Promise<void> {
        await ChatRouter.toggleParticipant(ctx, next, "remove");
    }

    private static async toggleParticipant(ctx: RouterContext, _: Next, action: "add" | "remove"): Promise<void> {
        const { body } = ctx.request;
        const { guid } = ctx.params;
        const address = body?.address;

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid: guid, withParticipants: true });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        // Add the participant to the chat
        let chat = chats[0];
        chat = await ChatInterface.toggleParticipant(chat, address, action);

        return new Success(ctx, { data: await ChatSerializer.serialize({ chat }) }).send();
    }

    static async getGroupIcon(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid: guid, withParticipants: false });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        const chat = chats[0];
        const icon = await ChatInterface.getGroupChatIcon(chat);
        if (!icon) {
            throw new NotFound({
                message: "The requested resource was not found",
                error: "Unable to find icon for the selected chat"
            });
        }

        return new FileStream(ctx, FileSystem.getRealPath(icon.filePath), icon.getMimeType() ?? "image/jfif").send();
    }

    static async setGroupChatIcon(ctx: RouterContext, _: Next) {
        const { files } = ctx.request;
        const { guid } = ctx.params;
        const icon = files?.icon as unknown as File;

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid: guid, withParticipants: true });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        await ChatInterface.setGroupChatIcon(chats[0], icon.path);
        return new Success(ctx, { message: "Successfully set group chat icon!" }).send();
    }

    static async removeGroupChatIcon(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid: guid, withParticipants: true });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        await ChatInterface.setGroupChatIcon(chats[0], null);
        return new Success(ctx, { message: "Successfully removed group chat icon!" }).send();
    }

    static async deleteChat(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;
        await ChatInterface.delete({ guid });
        return new Success(ctx, { message: `Successfully deleted chat!` }).send();
    }

    static async leaveChat(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;
        await ChatInterface.leave({ guid });
        return new Success(ctx, { message: `Successfully left chat!` }).send();
    }

    static async startTyping(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;
        await ChatInterface.startTyping(guid);
        return new Success(ctx, { message: `Successfully started typing!` }).send();
    }

    static async stopTyping(ctx: RouterContext, _: Next): Promise<void> {
        const { guid } = ctx.params;
        await ChatInterface.stopTyping(guid);
        return new Success(ctx, { message: `Successfully stopped typing!` }).send();
    }

    static async deleteChatMessage(ctx: RouterContext, _: Next) {
        const { guid: chatGuid, messageGuid } = ctx?.params ?? {};

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: false });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        const message = await Server().iMessageRepo.getMessage(messageGuid, false, false);
        if (isEmpty(message)) throw new NotFound({ error: "Message does not exist!" });

        await ChatInterface.deleteChatMessage(chats[0], message);
        return new Success(ctx, { message: 'Successfully deleted message!' }).send();
    }

    static async shouldShareContact(ctx: RouterContext, _: Next) {
        const { guid: chatGuid } = ctx?.params ?? {};

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: false });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        const canShare = await ChatInterface.canShareContactInfo(chats[0].guid);
        return new Success(ctx, { message: 'Successfully got contact sharing status!', data: canShare }).send();
    }

    static async shareContact(ctx: RouterContext, _: Next) {
        const { guid: chatGuid } = ctx?.params ?? {};

        const [chats, __] = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: false });
        if (isEmpty(chats)) throw new NotFound({ error: "Chat does not exist!" });

        await ChatInterface.shareContactInfo(chats[0].guid);
        return new Success(ctx, { message: 'Successfully shared contact info!' }).send();
    }
}
