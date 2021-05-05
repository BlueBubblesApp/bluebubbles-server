import { Connection } from "typeorm";
import {
    GetAttachmentsParams,
    GetChatsParams,
    GetHandlesParams,
    GetMessagesParams
} from "@server/plugins/messages_api/types";
import { convertDateTo2001Time } from "@server/helpers/dateUtil";

// All the custom plugin imports
import { Chat } from "./entity/Chat";
import { Handle } from "./entity/Handle";
import { Message } from "./entity/Message";
import { Attachment } from "./entity/Attachment";

export class ApiInterface {
    db: Connection;

    constructor(db: Connection) {
        this.db = db;
    }

    /**
     * Get all the chats from the DB
     *
     * @param identifier A specific chat identifier to get
     * @param withParticipants Whether to include the participants or not
     */
    async getChats({
        guid = null,
        withHandles = true,
        withMessages = false,
        includeArchived = true,
        includeSms = false,
        offset = 0,
        limit = null
    }: GetChatsParams): Promise<Chat[]> {
        const query = this.db.getRepository(Chat).createQueryBuilder("chat");

        // Inner-join because a chat must have participants
        if (withHandles) query.innerJoinAndSelect("chat.participants", "handle");

        // Add default WHERE clauses
        if (!includeSms) query.andWhere("chat.service_name = 'iMessage'");
        if (!includeArchived) query.andWhere("chat.is_archived = 0");
        if (guid) query.andWhere("chat.guid = :guid", { guid });

        // Set page params
        query.offset(offset);
        if (limit) query.limit(limit);

        // Get results
        const chats = await query.getMany();

        // Fetch messages for the chats, if enabled
        // We don't do this through SQL because it becomes
        // unreadable since it's limiting the results of a join
        if (withMessages) {
            for (let i = 0; i < chats.length; i += 1) {
                chats[i].messages = await this.getMessages({
                    chatGuid: chats[i].guid,
                    sort: "DESC",
                    limit: 25
                });
            }
        }
        return chats;
    }

    /**
     * Gets all participants in a chat
     *
     * @param guid A specific chat identifier to get
     */
    async getChatParticipants(guid: string): Promise<Handle[]> {
        const query = this.db.getRepository(Handle).createQueryBuilder("handle");

        // Inner-join because a handle may or may not have a chat technically
        query.leftJoinAndSelect("handle.chats", "chat");

        // Add in the param for the chat GUID
        query.andWhere("chat.guid = :guid", { guid });

        // Get results
        return query.getMany();
    }

    /**
     * Gets all messages
     *
     * @param guid A specific chat identifier to get
     */
    async getMessages({
        guid = null,
        chatGuid = null,
        associatedMessageGuid = null,
        withChats = true,
        withHandle = true,
        withOtherHandle = false,
        withAttachments = true,
        withAttachmentsData = false,
        includeSms = false,
        before = null,
        after = null,
        offset = 0,
        limit = 100,
        sort = "DESC",
        where = []
    }: GetMessagesParams): Promise<Message[]> {
        let beforeDate = before;
        let afterDate = after;

        // Sanitize some params
        if (after && typeof after === "number") afterDate = new Date(after);
        if (before && typeof before === "number") beforeDate = new Date(before);

        // Get messages with sender and the chat it's from
        const query = this.db.getRepository(Message).createQueryBuilder("message");

        if (withHandle) query.leftJoinAndSelect("message.handle", "handle");

        if (withAttachments)
            query.leftJoinAndSelect(
                "message.attachments",
                "attachment",
                "message.ROWID = message_attachment.message_id AND " +
                    "attachment.ROWID = message_attachment.attachment_id"
            );

        // Inner-join because all messages will have a chat
        if (chatGuid) {
            query
                .innerJoinAndSelect(
                    "message.chats",
                    "chat",
                    "message.ROWID = message_chat.message_id AND chat.ROWID = message_chat.chat_id"
                )
                .andWhere("chat.guid = :guid", { guid: chatGuid });
        } else if (withChats) {
            query.innerJoinAndSelect(
                "message.chats",
                "chat",
                "message.ROWID = message_chat.message_id AND chat.ROWID = message_chat.chat_id"
            );
        }

        // Add date restraints
        if (afterDate)
            query.andWhere("message.date >= :after", {
                after: convertDateTo2001Time(afterDate as Date)
            });
        if (beforeDate)
            query.andWhere("message.date < :before", {
                before: convertDateTo2001Time(beforeDate as Date)
            });
        if (guid) query.andWhere("message.guid = :guid", { guid });
        if (!includeSms) {
            query.andWhere("message.service = 'iMessage'");
        }

        let whereCpy = [...where];
        if (whereCpy && whereCpy.length > 0) {
            // If withSMS is enabled, remove any statements specifying the message service
            if (includeSms) {
                whereCpy = whereCpy.filter(item => item.statement !== `message.service = 'iMessage'`);
            }

            for (const item of whereCpy) {
                query.andWhere(item.statement, item.args);
            }
        }

        // Add pagination params
        query.orderBy("message.date", sort);
        query.offset(offset);
        query.limit(limit);

        return query.getMany();
    }

    /**
     * Helper for getting updated messages from the DB (delivered/read)
     *
     * @param guid A specific chat identifier to get
     */
    async getUpdatedMessages({
        chatGuid = null,
        withChats = true,
        withHandle = true,
        withAttachments = true,
        includeSms = false,
        before = null,
        after = null,
        offset = 0,
        limit = 100,
        sort = "DESC",
        where = []
    }: GetMessagesParams): Promise<Message[]> {
        let beforeDate = before;
        let afterDate = after;

        // Sanitize some params
        if (afterDate && typeof afterDate === "number") afterDate = new Date(afterDate);
        if (beforeDate && typeof beforeDate === "number") beforeDate = new Date(beforeDate);

        // Get messages with sender and the chat it's from
        const query = this.db.getRepository(Message).createQueryBuilder("message");

        if (withHandle) query.leftJoinAndSelect("message.handle", "handle");

        // Add the with attachments query
        if (withAttachments)
            query.leftJoinAndSelect(
                "message.attachments",
                "attachment",
                "message.ROWID = message_attachment.message_id AND " +
                    "attachment.ROWID = message_attachment.attachment_id"
            );

        // Inner-join because all messages will have a chat
        if (chatGuid) {
            query
                .innerJoinAndSelect(
                    "message.chats",
                    "chat",
                    "message.ROWID == message_chat.message_id AND chat.ROWID == message_chat.chat_id"
                )
                .andWhere("chat.guid = :guid", { guid: chatGuid });
        } else if (withChats) {
            query.innerJoinAndSelect(
                "message.chats",
                "chat",
                "message.ROWID == message_chat.message_id AND chat.ROWID == message_chat.chat_id"
            );
        }

        // Add default WHERE clauses
        query.andWhere("message.service == 'iMessage'");

        // Add any custom WHERE clauses
        if (where && where.length > 0) for (const item of where) query.andWhere(item.statement, item.args);

        // Add date_delivered constraints
        if (afterDate)
            query.andWhere("message.date_delivered >= :after", {
                after: convertDateTo2001Time(afterDate as Date)
            });
        if (beforeDate)
            query.andWhere("message.date_delivered < :before", {
                before: convertDateTo2001Time(beforeDate as Date)
            });

        // Add date_read constraints
        if (afterDate)
            query.orWhere("message.date_read >= :after", {
                after: convertDateTo2001Time(afterDate as Date)
            });
        if (beforeDate)
            query.andWhere("message.date_read < :before", {
                before: convertDateTo2001Time(beforeDate as Date)
            });

        // Add any custom WHERE clauses
        // We have to do this here so that it matches both before the OR and after the OR
        let whereCpy = [...where];
        if (whereCpy && whereCpy.length > 0) {
            // If withSMS is enabled, remove any statements specifying the message service
            if (includeSms) {
                whereCpy = whereCpy.filter(item => item.statement !== `message.service = 'iMessage'`);
            }

            for (const item of whereCpy) {
                query.andWhere(item.statement, item.args);
            }
        }

        // Add pagination params
        query.orderBy("message.date", sort);
        query.offset(offset);
        query.limit(limit);

        return query.getMany();
    }

    /**
     * Get the handles from the DB
     *
     * @param identifier A specific chat identifier to get
     * @param withParticipants Whether to include the participants or not
     */
    async getHandles({
        address = null,
        withChats = true,
        offset = 0,
        limit = null,
        where = []
    }: GetHandlesParams): Promise<Handle[]> {
        const query = this.db.getRepository(Handle).createQueryBuilder("handle");

        // Inner-join because a handle may or may not have a chat technically
        if (withChats) query.leftJoinAndSelect("handle.chats", "chat");

        // Add in the param for address querying
        if (address) query.andWhere("handle.id = :address OR handle.uncanonicalized_id = :address", { address });

        // Add in the where clauses
        for (const item of where ?? []) {
            query.andWhere(item.statement, item.args);
        }

        // Set page params
        query.offset(offset);
        if (limit) query.limit(limit);

        // Get results
        return query.getMany();
    }

    /**
     * Get the attachments from the DB
     *
     * @param identifier A specific chat identifier to get
     * @param withParticipants Whether to include the participants or not
     */
    async getAttachments({
        guid = null,
        withData = false,
        withMessages = false,
        offset = 0,
        limit = null,
        where = []
    }: GetAttachmentsParams): Promise<Attachment[]> {
        const query = this.db.getRepository(Attachment).createQueryBuilder("attachment");

        // Inner-join because a handle may or may not have a chat technically
        if (withMessages) query.leftJoinAndSelect("attachment.messages", "message");

        // Add in the param for guid querying
        if (guid) query.andWhere("attachment.guid = :guid", { guid });

        // Add in the where clauses
        for (const item of where ?? []) {
            query.andWhere(item.statement, item.args);
        }

        // Set page params
        query.offset(offset);
        if (limit) query.limit(limit);

        // Get results
        const attachments = await query.getMany();

        // Load attachments
        if (withData) {
            for (let i = 0; i < attachments.length; i += 1) {
                // Do nothing for now
            }
        }

        return attachments;
    }
}
