/* eslint-disable no-param-reassign */
import { Brackets, DataSource, SelectQueryBuilder } from "typeorm";

import { DBMessageParams, ChatParams, HandleParams, DBWhereItem } from "@server/databases/imessage/types";
import { convertDateTo2001Time } from "@server/databases/imessage/helpers/dateUtil";
import { Chat } from "@server/databases/imessage/entity/Chat";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { Message } from "@server/databases/imessage/entity/Message";
import { Attachment } from "@server/databases/imessage/entity/Attachment";
import { isNotEmpty } from "@server/helpers/utils";
import { isMinHighSierra, isMinVentura } from "@server/env";
import { Loggable } from "@server/lib/logging/Loggable";

/**
 * A repository class to facilitate pulling information from the iMessage database
 */
export class MessageRepository extends Loggable {
    tag = "MessageRepository";

    db: DataSource = null;

    dbPath: string;

    dbPathWal: string;

    constructor() {
        super();
        this.dbPath = `${process.env.HOME}/Library/Messages/chat.db`;
        this.dbPathWal = `${process.env.HOME}/Library/Messages/chat.db-wal`;
        this.db = null;
    }

    /**
     * Creates a connection to the iMessage database
     */
    async initialize() {
        this.db = new DataSource({
            name: "iMessage",
            type: "better-sqlite3",
            database: this.dbPath,
            entities: [Chat, Handle, Message, Attachment]
        });

        this.db = await this.db.initialize();
        return this.db;
    }

    async getiMessageAccount() {
        const query = this.db.getRepository(Chat)
            .createQueryBuilder("chat")
            .where("chat.service_name = 'iMessage'")
            .limit(1)
            .orderBy("chat.ROWID", "DESC");
        const chat = await query.getOne();
        return chat ? chat.accountLogin.split(':').at(-1) : null;
    }

    /**
     * Get all the chats from the DB
     *
     * @param identifier A specific chat identifier to get
     * @param withParticipants Whether to include the participants or not
     */
    async getChats({
        chatGuid = null,
        globGuid = false,
        withParticipants = true,
        withArchived = true,
        withLastMessage = false,
        offset = 0,
        limit = null,
        where = [],
        orderBy = "chat.ROWID",
    }: ChatParams = {}): Promise<[Chat[], number]> {
        const query = this.db.getRepository(Chat).createQueryBuilder("chat");

        // Inner-join because a chat must have participants
        if (withParticipants) {
            query.innerJoinAndSelect("chat.participants", "handle");
        }

        // Left join because technically a chat might not have a last message
        if (withLastMessage) {
            query.leftJoinAndSelect("chat.messages", "message");
        }

        if (!withArchived) query.andWhere("chat.is_archived == 0");
        if (chatGuid) {
            if (globGuid) {
                query.andWhere("chat.guid LIKE :guid", { guid: `%${chatGuid}%` });
            } else {
                query.andWhere("chat.guid = :guid", { guid: chatGuid });
            }
        }

        // Add any custom WHERE clauses
        if (isNotEmpty(where)) {
            query.andWhere(
                new Brackets(qb => {
                    for (const item of where) {
                        qb.andWhere(item.statement, item.args);
                    }
                })
            );
        }

        // Add clause to fetch with last message
        if (withLastMessage) {
            query.groupBy("chat.guid");
            query.having("message.ROWID = MAX(message.ROWID)");
        }

        query.orderBy(orderBy, "DESC");

        // Set page params
        if (offset != null) query.skip(offset);
        if (limit != null) query.take(limit);

        // Get results
        return await query.getManyAndCount();
    }

    async getChatLastMessage(chatGuid: string): Promise<Message> {
        const query = this.db.getRepository(Message).createQueryBuilder("message");
        query.innerJoinAndSelect("message.chats", "chat");
        query.andWhere("chat.guid = :guid", { guid: chatGuid });
        query.orderBy("message.dateCreated", "DESC");
        query.take(1);

        // Get results
        const message = await query.getOne();
        return message;
    }

    /**
     * Get participants of a chat, in order of being added.
     * This is a weird method because of the way SQLite will auto-sort
     *
     * @param identifier A specific chat identifier to get
     */
    async getParticipantOrder(chatROWID: number) {
        const query = await this.db.query("SELECT * FROM chat_handle_join");

        // We have to do manual filtering in order to maintain the order
        // SQLite will auto-sort results if there is no Primary Key (which there isn't)
        return query.filter((item: { chat_id: number; handle_id: number }) => item.chat_id === chatROWID);
    }

    /**
     * Get an attachment from the DB
     *
     * @param attachmentGuid A specific attachment identifier to get
     * @param withMessages Whether to include the participants or not
     */
    async getAttachment(attachmentGuid: string, withMessages = false) {
        const query = this.db.getRepository(Attachment).createQueryBuilder("attachment");

        if (withMessages) query.leftJoinAndSelect("attachment.messages", "message");

        // Attachment GUIDs may start with a prefix such as p:/ or `at_x_`. For lookups,
        // all we need is the actual GUID, which is the last 36 digits.
        // Original GUIDs can also be prefixed with at_x_ or p:/.
        const lookupGuids = [attachmentGuid];
        if (attachmentGuid.length > 36) {
            lookupGuids.push(attachmentGuid.substring(attachmentGuid.length - 36));
        }

        for (const lookupGuid of lookupGuids) {
            // El Capitan does not have an original_guid column.
            if (isMinHighSierra) {
                query.where("attachment.original_guid LIKE :guid", { guid: `%${lookupGuid}` });
                query.orWhere("attachment.guid LIKE :guid", { guid: `%${lookupGuid}` });
            } else {
                query.where("attachment.guid LIKE :guid", { guid: `%${lookupGuid}` });
            }
            const attachment = await query.getOne();
            if (attachment) return attachment;
        }
        return null;
    }

    /**
     * Get an attachment from the DB
     *
     * @param guid A specific message identifier to get
     * @param withMessages Whether to include the participants or not
     */
    async getMessage(guid: string, withChats = true, withAttachments = false) {
        const query = this.db.getRepository(Message).createQueryBuilder("message");
        query.leftJoinAndSelect("message.handle", "handle");

        if (withChats) query.leftJoinAndSelect("message.chats", "chat");

        if (withAttachments)
            query.leftJoinAndSelect(
                "message.attachments",
                "attachment",
                "message.ROWID = message_attachment.message_id AND " +
                    "attachment.ROWID = message_attachment.attachment_id"
            );

        query.andWhere("message.guid = :guid", { guid });

        const message = await query.getOne();
        return message;
    }

    /**
     * Get all the handles from the DB
     *
     * @param handle Get a specific handle from the DB
     */
    async getHandles({ address = null, limit = 1000, offset = 0 }: HandleParams): Promise<[Handle[], number]> {
        // Start a query
        const query = this.db.getRepository(Handle).createQueryBuilder("handle");

        // Add a handle query
        if (address) {
            query.where("handle.id LIKE :address", { address: `%${address.replace("+", "")}` });
        }

        // Add pagination params
        query.skip(offset);
        query.take(limit);

        return await query.getManyAndCount();
    }

    /**
     * Query the messages table
     *
     * @param offset The offset to start getting the messages from
     * @param limit The max number of messages to return
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getMessages({
        chatGuid = null,
        offset = 0,
        limit = 100,
        after = null,
        before = null,
        withChats = false,
        withChatParticipants = false,
        withAttachments = true,
        sort = "DESC",
        orderBy = "message.dateCreated",
        where = []
    }: DBMessageParams): Promise<[Message[], number]> {
        // Sanitize some params
        if (after && typeof after === "number") after = new Date(after);
        if (before && typeof before === "number") before = new Date(before);

        // Get messages with sender and the chat it's from
        const query = this.db
            .getRepository(Message)
            .createQueryBuilder("message")
            .leftJoinAndSelect("message.handle", "handle");

        if (withAttachments)
            query.leftJoinAndSelect(
                "message.attachments",
                "attachment"
            );

        // Inner-join because all messages will have a chat
        if (chatGuid) {
            query
                .innerJoinAndSelect(
                    "message.chats",
                    "chat"
                )
                .andWhere("chat.guid = :guid", { guid: chatGuid });
        } else if (withChats) {
            query.innerJoinAndSelect(
                "message.chats",
                "chat"
            );
        }

        if (withChatParticipants) {
            query.innerJoinAndSelect("chat.participants", "chandle");
        }

        // Add any custom WHERE clauses
        if (isNotEmpty(where)) {
            query.andWhere(
                new Brackets(qb => {
                    for (const item of where) {
                        qb.andWhere(item.statement, item.args);
                    }
                })
            );
        }

        if (after || before) {
            this.applyMessageDateQuery(query, after as Date, before as Date);
        }

        // Add pagination params
        query.orderBy(orderBy, sort);
        query.skip(offset);
        query.take(limit);

        return await query.getManyAndCount();
    }

    /**
     * Query the messages table
     *
     * @param offset The offset to start getting the messages from
     * @param limit The max number of messages to return
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getMessagesRaw({
        chatGuid = null,
        offset = 0,
        limit = 100,
        after = null,
        before = null,
        withChats = false,
        withChatParticipants = false,
        withAttachments = true,
        sort = "DESC",
        orderBy = "message.dateCreated",
        where = []
    }: DBMessageParams): Promise<any[]> {
        // Sanitize some params
        if (after && typeof after === "number") after = new Date(after);
        if (before && typeof before === "number") before = new Date(before);

        // Get messages with sender and the chat it's from
        const query = this.db
            .getRepository(Message)
            .createQueryBuilder("message")
            .leftJoinAndSelect("message.handle", "handle");

        if (withAttachments)
            query.leftJoinAndSelect(
                "message.attachments",
                "attachment"
            );

        // Inner-join because all messages will have a chat
        if (chatGuid) {
            query
                .innerJoinAndSelect(
                    "message.chats",
                    "chat"
                )
                .andWhere("chat.guid = :guid", { guid: chatGuid });
        } else if (withChats) {
            query.innerJoinAndSelect(
                "message.chats",
                "chat"
            );
        }

        if (withChatParticipants) {
            query.innerJoinAndSelect("chat.participants", "chandle");
        }

        // Add any custom WHERE clauses
        if (isNotEmpty(where)) {
            query.andWhere(
                new Brackets(qb => {
                    for (const item of where) {
                        qb.andWhere(item.statement, item.args);
                    }
                })
            );
        }

        if (after || before) {
            this.applyMessageDateQuery(query, after as Date, before as Date);
        }

        // Add pagination params
        query.orderBy(orderBy, sort);
        query.skip(offset);
        query.take(limit);

        const [sql, parameters] = query.getQueryAndParameters();
        const results = await this.db.query(sql, parameters);
        return results;
    }

    /**
     * Gets all messages that have been updated
     *
     * @param chat The chat to get the messages from
     * @param offset The offset to start getting the messages from
     * @param limit The max number of messages to return
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getUpdatedMessages({
        chatGuid = null,
        offset = 0,
        limit = 100,
        after = null,
        before = null,
        withChats = false,
        withAttachments = true,
        includeCreated = false,
        sort = "DESC",
        where = []
    }: DBMessageParams) {
        // Sanitize some params
        if (after && typeof after === "number") after = new Date(after);
        if (before && typeof before === "number") before = new Date(before);

        // Get messages with sender and the chat it's from
        const query = this.db
            .getRepository(Message)
            .createQueryBuilder("message")
            .leftJoinAndSelect("message.handle", "handle");

        if (withAttachments)
            query.leftJoinAndSelect(
                "message.attachments",
                "attachment"
            );

        // Inner-join because all messages will have a chat
        if (chatGuid) {
            query
                .innerJoinAndSelect(
                    "message.chats",
                    "chat"
                )
                .andWhere("chat.guid = :guid", { guid: chatGuid });
        } else if (withChats) {
            query.innerJoinAndSelect(
                "message.chats",
                "chat"
            );
        }

        // Add any custom WHERE clauses
        if (isNotEmpty(where)) {
            query.andWhere(
                new Brackets(qb => {
                    for (const item of where) {
                        qb.andWhere(item.statement, item.args);
                    }
                })
            );
        }

        // Add date_delivered constraints
        if (after || before) {
            this.applyMessageUpdateDateQuery(query, after as Date, before as Date, includeCreated);
        }

        // Add pagination params
        query.orderBy("message.dateCreated", sort);
        query.skip(offset);
        query.take(limit);

        return await query.getMany();
    }

    /**
     * Gets message counts associated with a chat
     *
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getMessageCount({
        after = null,
        before = null,
        isFromMe = false,
        where = [],
        chatGuid = null,
        updated = false,
        minRowId = null,
        maxRowId = null
    }: {
        after?: Date;
        before?: Date;
        isFromMe?: boolean;
        where?: DBWhereItem[];
        chatGuid?: string;
        updated?: boolean;
        minRowId?: number;
        maxRowId?: number;
    } = {}): Promise<number> {
        // Get messages with sender and the chat it's from
        const query = this.db.getRepository(Message).createQueryBuilder("message");

        // Add chatGuid (if applicable)
        if (isNotEmpty(chatGuid)) {
            query
                .innerJoinAndSelect(
                    "message.chats",
                    "chat",
                    "message.ROWID == message_chat.message_id AND chat.ROWID == message_chat.chat_id"
                )
                .andWhere("chat.guid = :guid", { guid: chatGuid });
        }

        if (isFromMe) query.andWhere("message.is_from_me = 1");
        if (minRowId != null) query.andWhere("message.ROWID >= :minRowId", { minRowId });
        if (maxRowId != null) query.andWhere("message.ROWID <= :maxRowId", { maxRowId });

        // Add any custom WHERE clauses
        if (isNotEmpty(where)) {
            query.andWhere(
                new Brackets(qb => {
                    for (const item of where) {
                        qb.andWhere(item.statement, item.args);
                    }
                })
            );
        }

        // Add date constraints
        if (after || before) {
            if (updated) {
                this.applyMessageUpdateDateQuery(query, after, before);
            } else {
                this.applyMessageDateQuery(query, after, before);
            }
        }

        return await query.getCount();
    }

    async getAttachmentsForMessage(message: Message) {
        const attachments = this.db
            .getRepository(Attachment)
            .createQueryBuilder("attachment")
            // Inner join because an attachment can't exist without a message
            .innerJoinAndSelect("attachment.messages", "message")
            .where("message.ROWID = :id", { id: message.ROWID });

        return await attachments.getMany();
    }

    /**
     * Count messages associated with different chats
     *
     * @param chatStyle Whether you are fetching the count for a group or individual chat
     */
    async getChatMessageCounts(chatStyle: "group" | "individual", after: Date = null) {
        let result = null;

        // Get messages with sender and the chat it's from
        if (!after) {
            result = await this.db.getRepository(Chat).query(
                `SELECT
                    chat.guid AS chat_guid,
                    chat.display_name AS group_name,
                    COUNT(message.ROWID) AS message_count
                FROM chat
                JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
                JOIN message ON message.ROWID = cmj.message_id
                WHERE chat.style = ?
                GROUP BY chat.guid;`,
                [chatStyle === "group" ? 43 : 45]
            );
        } else {
            result = await this.db.getRepository(Chat).query(
                `SELECT
                    chat.guid AS chat_guid,
                    chat.display_name AS group_name,
                    COUNT(message.ROWID) AS message_count
                FROM chat
                JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
                JOIN message ON message.ROWID = cmj.message_id
                WHERE message.date >= ? AND chat.style = ?
                GROUP BY chat.guid;`,
                [
                    convertDateTo2001Time(after),
                    chatStyle === "group" ? 43 : 45
                ]
            );
        }

        return result;
    }

    /**
     * Count messages associated with different chats
     *
     * @param chatStyle Whether you are fetching the count for a group or individual chat
     */
    async getMediaCountsByChat({
        mediaType = "image",
        after = null
    }: {
        mediaType?: "image" | "video" | "location" | "other";
        after?: Date;
    } = {}) {
        let result = null;

        // Get messages with sender and the chat it's from
        if (!after) {
            result = await this.db.getRepository(Chat).query(
                `SELECT
                    chat.guid AS chat_guid,
                    chat.display_name AS group_name,
                    COUNT(attachment.ROWID) AS media_count
                FROM chat
                JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
                JOIN message ON message.ROWID = cmj.message_id
                JOIN message_attachment_join AS maj ON message.ROWID = maj.message_id
                JOIN attachment ON attachment.ROWID = maj.attachment_id
                WHERE attachment.mime_type LIKE '${mediaType}%'
                GROUP BY chat.guid;`
            );
        } else {
            result = await this.db.getRepository(Chat).query(
                `SELECT
                    chat.guid AS chat_guid,
                    chat.display_name AS group_name,
                    COUNT(attachment.ROWID) AS media_count
                FROM chat
                JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
                JOIN message ON message.ROWID = cmj.message_id
                JOIN message_attachment_join AS maj ON message.ROWID = maj.message_id
                JOIN attachment ON attachment.ROWID = maj.attachment_id
                WHERE message.date >= ? AND attachment.mime_type LIKE '${mediaType}%'
                GROUP BY chat.guid;`,
                [
                    convertDateTo2001Time(after)
                ]
            );
        }

        return result;
    }

    async getMediaCounts({
        mediaType = "image",
        after = null
    }: {
        mediaType?: "image" | "video" | "location";
        after?: Date
    } = {}) {
        let mType: string = mediaType;
        if (mType === "location") {
            mType = "text/x-vlocation";
        }

        let result = null;

        // Get messages with sender and the chat it's from
        if (!after) {
            result = await this.db.getRepository(Chat).query(
                `SELECT COUNT(attachment.ROWID) AS media_count
                FROM attachment
                WHERE attachment.mime_type LIKE '${mType}%';`
            );
        } else {
            result = await this.db.getRepository(Chat).query(
                `SELECT COUNT(attachment.ROWID) AS media_count
                FROM attachment
                WHERE attachment.date >= ? AND attachment.mime_type LIKE '${mType}%';`,
                [
                    convertDateTo2001Time(after)
                ]
            );
        }

        return result;
    }

    applyMessageDateQuery(query: SelectQueryBuilder<Message>, after?: Date, before?: Date) {
        query.andWhere(
            new Brackets(qb => {
                if (after)
                    qb.andWhere("message.date >= :after", {
                        after: convertDateTo2001Time(after)
                    });
                if (before)
                    qb.andWhere("message.date <= :before", {
                        before: convertDateTo2001Time(before)
                    });
            })
        );
    }

    applyMessageUpdateDateQuery(
        query: SelectQueryBuilder<Message>,
        after?: Date,
        before?: Date,
        includeCreated = false
    ) {
        query.andWhere(
            new Brackets(qb => {
                if (includeCreated) {
                    qb.orWhere(
                        new Brackets(qb2 => {
                            if (after)
                                qb2.andWhere("message.date >= :after", {
                                    after: convertDateTo2001Time(after)
                                });
                            if (before)
                                qb2.andWhere("message.date <= :before", {
                                    before: convertDateTo2001Time(before)
                                });
                        })
                    );
                }

                qb.orWhere(
                    new Brackets(qb2 => {
                        if (after)
                            qb2.andWhere("message.date_delivered >= :after", {
                                after: convertDateTo2001Time(after)
                            });
                        if (before)
                            qb2.andWhere("message.date_delivered <= :before", {
                                before: convertDateTo2001Time(before)
                            });
                    })
                );

                qb.orWhere(
                    new Brackets(qb2 => {
                        if (after)
                            qb2.andWhere("message.date_read >= :after", {
                                after: convertDateTo2001Time(after)
                            });
                        if (before)
                            qb2.andWhere("message.date_read <= :before", {
                                before: convertDateTo2001Time(before)
                            });
                    })
                );

                if (isMinVentura) {
                    qb.orWhere(
                        new Brackets(qb2 => {
                            if (after)
                                qb2.andWhere("message.date_edited >= :after", {
                                    after: convertDateTo2001Time(after)
                                });
                            if (before)
                                qb2.andWhere("message.date_edited <= :before", {
                                    before: convertDateTo2001Time(before)
                                });
                        })
                    );
                }

                if (isMinVentura) {
                    qb.orWhere(
                        new Brackets(qb2 => {
                            if (after)
                                qb2.andWhere("message.date_retracted >= :after", {
                                    after: convertDateTo2001Time(after)
                                });
                            if (before)
                                qb2.andWhere("message.date_retracted <= :before", {
                                    before: convertDateTo2001Time(before)
                                });
                        })
                    );
                }
            })
        );
    }

    /**
     * Gets message counts associated with a chat
     *
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getAttachmentCount() {
        // Get messages with sender and the chat it's from
        const query = this.db.getRepository(Attachment).createQueryBuilder("attachment");
        const count = await query.getCount();
        return count;
    }

    async getChatCount() {
        // Get messages with sender and the chat it's from
        const query = this.db.getRepository(Chat).createQueryBuilder("chat");
        const count = await query.getCount();
        return count;
    }

    async getHandleCount() {
        // Get messages with sender and the chat it's from
        const query = this.db.getRepository(Handle).createQueryBuilder("handle");
        const count = await query.getCount();
        return count;
    }
}
