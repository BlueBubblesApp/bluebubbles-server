/* eslint-disable prefer-const */
import { RouterContext } from "koa-router";
import { Next } from "koa";
import type { File } from "formidable";

import { Server } from "@server";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { Message } from "@server/databases/imessage/entity/Message";
import { MessageInterface } from "@server/api/v1/interfaces/messageInterface";
import { MessagePromiseRejection } from "@server/managers/outgoingMessageManager/messagePromise";
import { MessageSerializer } from "@server/api/v1/serializers/MessageSerializer";
import { arrayHasOne } from "@server/utils/CollectionUtils";
import { Success } from "../responses/success";
import { BadRequest, IMessageError, NotFound } from "../responses/errors";
import { parseWithQuery } from "../utils";

export class MessageRouter {
    static async sentCount(ctx: RouterContext, _: Next) {
        const total = await Server().iMessageRepo.getMessageCount(null, null, true);
        return new Success(ctx, { data: { total } }).send();
    }

    static async count(ctx: RouterContext, _: Next) {
        const { after, before, chatGuid } = ctx.request.query;
        const beforeDate = isNotEmpty(before) ? new Date(Number.parseInt(before as string, 10)) : null;
        const afterDate = isNotEmpty(after) ? new Date(Number.parseInt(after as string, 10)) : null;
        const total = await Server().iMessageRepo.getMessageCount(afterDate, beforeDate, false, chatGuid as string);
        return new Success(ctx, { data: { total } }).send();
    }

    static async countUpdated(ctx: RouterContext, _: Next) {
        const { after, before, chatGuid } = ctx.request.query;
        const beforeDate = isNotEmpty(before) ? new Date(Number.parseInt(before as string, 10)) : null;
        const afterDate = isNotEmpty(after) ? new Date(Number.parseInt(after as string, 10)) : null;
        const total = await Server().iMessageRepo.getMessageCount(
            afterDate,
            beforeDate,
            false,
            chatGuid as string,
            true
        );
        return new Success(ctx, { data: { total } }).send();
    }

    static async find(ctx: RouterContext, _: Next) {
        const { guid } = ctx.params;
        const withQuery = parseWithQuery(ctx.request.query.with);
        const withChats = arrayHasOne(withQuery, ["chats", "chat"]);
        const withParticipants = arrayHasOne(withQuery, ["chats.participants", "chat.participants"]);
        const withAttachments = arrayHasOne(withQuery, ["attachment", "attachments"]);

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
                    withArchived: true
                });

                if (isEmpty(chats)) continue;
                i.participants = chats[0].participants;
            }
        }

        return new Success(ctx, { data: await MessageSerializer.serialize({ message }) }).send();
    }

    static async query(ctx: RouterContext, _: Next) {
        let {
            chatGuid,
            with: withQuery,
            offset,
            limit,
            where,
            sort,
            after,
            before,
            convertAttachments
        } = ctx?.request?.body ?? {};

        // Pull out the filters
        withQuery = parseWithQuery(withQuery);
        const withChats = arrayHasOne(withQuery, ["chat", "chats"]);
        const withAttachments = arrayHasOne(withQuery, ["attachment", "attachments"]);
        const withAttachmentMetadata = arrayHasOne(withQuery, ["attachment.metadata", "attachments.metadata"]);
        const withHandle = arrayHasOne(withQuery, ["handle", "handles"]);
        const withChatParticipants = arrayHasOne(withQuery, ["chat.participants", "chats.participants"]);
        const withAttributedBody = arrayHasOne(withQuery, ["attributedbody", "attributed-body"]);

        // We don't need to worry about it not being a number because
        // the validator checks for that. It also checks for min values.
        offset = offset ? Number.parseInt(offset, 10) : 0;
        limit = limit ? Number.parseInt(limit, 10) : 100;

        if (chatGuid) {
            const chats = await Server().iMessageRepo.getChats({ chatGuid });
            if (isEmpty(chats))
                return new Success(ctx, {
                    message: `No chat found with GUID: ${chatGuid}`,
                    data: []
                });
        }

        // Fetch the info for the message by GUID
        const messages = await Server().iMessageRepo.getMessages({
            chatGuid,
            withChats: withChats || withChatParticipants,
            withAttachments,
            withHandle,
            offset,
            limit,
            sort,
            before,
            after,
            where: where ?? []
        });

        const data = await MessageSerializer.serializeList({
            messages,
            attachmentConfig: {
                loadMetadata: withAttachmentMetadata,
                convert: convertAttachments
            },
            parseAttributedBody: withAttributedBody,
            loadChatParticipants: withChatParticipants
        });

        // Build metadata to return
        const metadata = { offset, limit, total: data.length };
        return new Success(ctx, { data, message: "Successfully fetched messages!", metadata }).send();
    }

    static async sendText(ctx: RouterContext, _: Next) {
        let { tempGuid, message, attributedBody, method, chatGuid, effectId, subject, selectedMessageGuid } =
            ctx?.request?.body ?? {};

        // Add to send cache
        Server().httpService.sendCache.add(tempGuid);

        try {
            // Send the message
            const sentMessage = await MessageInterface.sendMessageSync({
                chatGuid,
                message,
                method,
                attributedBody,
                subject,
                effectId,
                selectedMessageGuid,
                tempGuid
            });

            // Remove from cache
            Server().httpService.sendCache.remove(tempGuid);

            // Convert to an API response
            // No need to load the participants since we sent the message
            const data = await MessageSerializer.serialize({ message: sentMessage, loadChatParticipants: false });

            // Inject the TempGUID back into the response
            if (isNotEmpty(tempGuid)) {
                data.tempGuid = tempGuid;
            }

            if ((data.error ?? 0) !== 0) {
                throw new IMessageError({
                    message: "Message sent with an error. See attached message",
                    error: "Message failed to send!",
                    data
                });
            } else {
                return new Success(ctx, { message: "Message sent!", data }).send();
            }
        } catch (ex: any) {
            // Remove from cache
            Server().httpService.sendCache.remove(tempGuid);

            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Message Send Error",
                    // No need to load the participants since we sent the message
                    data: await MessageSerializer.serialize({ message: ex, loadChatParticipants: false }),
                    error: "Failed to send message! See attached message error code."
                });
            } else if (ex instanceof MessagePromiseRejection) {
                throw new IMessageError({
                    message: "Message Send Error",
                    // No need to load the participants since we sent the message
                    data: ex?.msg
                        ? await MessageSerializer.serialize({ message: ex.msg, loadChatParticipants: false })
                        : null,
                    error: "Failed to send message! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Message Send Error", error: ex?.message ?? ex.toString() });
            }
        }
    }

    static async sendAttachment(ctx: RouterContext, _: Next) {
        const { files } = ctx.request;
        const { tempGuid, chatGuid, name } = ctx.request?.body ?? {};
        const attachment = files?.attachment as File;

        // Add to send cache
        Server().httpService.sendCache.add(tempGuid);

        // Send the attachment
        try {
            const sentMessage: Message = await MessageInterface.sendAttachmentSync({
                chatGuid,
                attachmentPath: attachment.path,
                attachmentName: name,
                attachmentGuid: tempGuid
            });

            // Remove from cache
            Server().httpService.sendCache.remove(tempGuid);

            // Convert to an API response
            // No need to load the participants since we sent the message
            const data = await MessageSerializer.serialize({ message: sentMessage, loadChatParticipants: false });
            return new Success(ctx, { message: "Attachment sent!", data }).send();
        } catch (ex: any) {
            // Remove from cache
            Server().httpService.sendCache.remove(tempGuid);

            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Attachment Send Error",
                    // No need to load the participants since we sent the message
                    data: await MessageSerializer.serialize({ message: ex, loadChatParticipants: false }),
                    error: "Failed to send attachment! See attached message error code."
                });
            } else if (ex instanceof MessagePromiseRejection) {
                throw new IMessageError({
                    message: "Attachment Send Error",
                    // No need to load the participants since we sent the message
                    data: ex?.msg
                        ? await MessageSerializer.serialize({ message: ex.msg, loadChatParticipants: false })
                        : null,
                    error: "Failed to send attachment! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Attachment Send Error", error: ex?.message ?? ex.toString() });
            }
        }
    }

    static async react(ctx: RouterContext, _: Next) {
        const { chatGuid, selectedMessageGuid, reaction, partIndex } = ctx?.request?.body ?? {};

        // Fetch the message we are reacting to
        const message = await Server().iMessageRepo.getMessage(selectedMessageGuid, false, true);
        if (!message) throw new BadRequest({ error: "Selected message does not exist!" });

        // Send the reaction
        try {
            const sentMessage = await MessageInterface.sendReaction({ chatGuid, message, reaction, partIndex });
            return new Success(ctx, {
                message: "Reaction sent!",
                // No need to load the participants since we sent the message
                data: await MessageSerializer.serialize({ message: sentMessage, loadChatParticipants: false })
            }).send();
        } catch (ex: any) {
            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Reaction Send Error",
                    // No need to load the participants since we sent the message
                    data: await MessageSerializer.serialize({ message: ex, loadChatParticipants: false }),
                    error: "Failed to send reaction! See attached message error code."
                });
            } else if (ex instanceof MessagePromiseRejection) {
                throw new IMessageError({
                    message: "Reaction Send Error",
                    // No need to load the participants since we sent the message
                    data: ex?.msg
                        ? await MessageSerializer.serialize({ message: ex.msg, loadChatParticipants: false })
                        : null,
                    error: "Failed to send reaction! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Reaction Send Error", error: ex?.message ?? ex.toString() });
            }
        }
    }

    static async unsendMessage(ctx: RouterContext, _: Next) {
        const { guid: messageGuid } = ctx.params ?? {};
        const { partIndex } = ctx?.request?.body ?? {};

        // Fetch the message we are reacting to
        const message = await Server().iMessageRepo.getMessage(messageGuid, true, true);
        if (!message) throw new BadRequest({ error: "Selected message does not exist!" });

        if (isEmpty(message?.chats ?? [])) throw new BadRequest({ error: "Associated chat not found!" });
        const chatGuid = message.chats[0].guid;

        // Unsend the message
        try {
            const unsentMessage = await MessageInterface.unsendMessage({ chatGuid, messageGuid, partIndex });
            return new Success(ctx, {
                message: "Message unsent!",
                // No need to load the participants since we sent the message
                data: await MessageSerializer.serialize({ message: unsentMessage, loadChatParticipants: false })
            }).send();
        } catch (ex: any) {
            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Unsend Message Error",
                    // No need to load the participants since we sent the message
                    data: await MessageSerializer.serialize({ message: ex, loadChatParticipants: false }),
                    error: "Failed to unsend message! See attached message error code."
                });
            } else if (ex instanceof MessagePromiseRejection) {
                throw new IMessageError({
                    message: "Unsend Message Error",
                    // No need to load the participants since we sent the message
                    data: ex?.msg
                        ? await MessageSerializer.serialize({ message: ex.msg, loadChatParticipants: false })
                        : null,
                    error: "Failed to unsend message! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Unsend Message Error", error: ex?.message ?? ex.toString() });
            }
        }
    }

    static async editMessage(ctx: RouterContext, _: Next) {
        const { guid: messageGuid } = ctx.params ?? {};
        const { editedMessage, backwardsCompatibilityMessage, partIndex } = ctx?.request?.body ?? {};

        // Fetch the message we are reacting to
        const message = await Server().iMessageRepo.getMessage(messageGuid, false, true);
        if (!message) throw new BadRequest({ error: "Selected message does not exist!" });

        if (isEmpty(message?.chats ?? [])) throw new BadRequest({ error: "Associated chat not found!" });
        const chatGuid = message.chats[0].guid;

        // Edit the message
        try {
            const changedMessage = await MessageInterface.editMessage({
                chatGuid,
                messageGuid,
                editedMessage,
                backwardsCompatMessage: backwardsCompatibilityMessage,
                partIndex
            });

            return new Success(ctx, {
                message: "Message edited!",
                // No need to load the participants since we sent the message
                data: await MessageSerializer.serialize({ message: changedMessage, loadChatParticipants: false })
            }).send();
        } catch (ex: any) {
            if (ex instanceof Message) {
                throw new IMessageError({
                    message: "Message Edit Error",
                    // No need to load the participants since we sent the message
                    data: await MessageSerializer.serialize({ message: ex, loadChatParticipants: false }),
                    error: "Failed to edit message! See attached message error code."
                });
            } else if (ex instanceof MessagePromiseRejection) {
                throw new IMessageError({
                    message: "Message Edit Error",
                    // No need to load the participants since we sent the message
                    data: ex?.msg
                        ? await MessageSerializer.serialize({ message: ex.msg, loadChatParticipants: false })
                        : null,
                    error: "Failed to edit message! See attached message error code."
                });
            } else {
                throw new IMessageError({ message: "Message Edit Error", error: ex?.message ?? ex.toString() });
            }
        }
    }
}
