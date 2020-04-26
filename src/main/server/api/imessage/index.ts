/* eslint-disable no-param-reassign */
import { createConnection, Connection } from "typeorm";

import { convertDateTo2001Time } from "@server/api/imessage/helpers/dateUtil";
import { Chat } from "@server/api/imessage/entity/Chat";
import { Handle } from "@server/api/imessage/entity/Handle";
import { Message } from "@server/api/imessage/entity/Message";
import { Attachment } from "./entity/Attachment";

/**
 * A repository class to facilitate pulling information from the iMessage database
 */
export class DatabaseRepository {
    db: Connection = null;

    constructor() {
        this.db = null;
    }

    /**
     * Creates a connection to the iMessage database
     */
    async initialize() {
        this.db = await createConnection({
            name: "iMessage",
            type: "sqlite",
            database: `${process.env.HOME}/Library/Messages/chat.db`,
            entities: [Chat, Handle, Message, Attachment],
            synchronize: false,
            logging: false
        });

        return this.db;
    }

    /**
     * Get all the chats from the DB
     *
     * @param identifier A specific chat identifier to get
     * @param withParticipants Whether to include the participants or not
     */
    async getChats(chatGuid?: string, withParticipants = true) {
        const query = this.db.getRepository(Chat).createQueryBuilder("chat");

        if (withParticipants)
            query.leftJoinAndSelect("chat.participants", "handle");

        // Add default WHERE clauses
        query.andWhere("chat.service_name == 'iMessage'");
        if (chatGuid)
            query.andWhere("chat.guid == :guid", { guid: chatGuid });

        const chats = await query.getMany();
        return chats;
    }

    /**
     * Get all the handles from the DB
     *
     * @param handle Get a specific handle from the DB
     */
    async getHandles(handle: string = null) {
        const repo = this.db.getRepository(Handle);
        let handles = [];

        // Get all handles or just get one handle
        if (handle) {
            handles = await repo.find({ id: handle });
        } else {
            handles = await repo.find();
        }

        return handles;
    }

    /**
     * Gets all messages associated with a chat
     *
     * @param chat The chat to get the messages from
     * @param offset The offset to start getting the messages from
     * @param limit The max number of messages to return
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getMessages(
        chatGuid: string,
        offset = 0,
        limit = 100,
        after?: Date,
        before?: Date
    ) {
        // Get messages with sender and the chat it's from
        const query = this.db
            .getRepository(Message)
            .createQueryBuilder("message")
            .leftJoinAndSelect("message.from", "handle")
            .leftJoinAndSelect(
                "message.chats",
                "chat",
                "message.ROWID == message_chat.message_id AND chat.ROWID == message_chat.chat_id"
            )
            .leftJoinAndSelect(
                "message.attachments",
                "attachment",
                "message.ROWID == message_attachment.message_id AND attachment.ROWID == message_attachment.attachment_id"
            );

        if (chatGuid)
            query.andWhere("chat.guid = :guid", { guid: chatGuid });

        // Add default WHERE clauses
        query
            .andWhere("message.service == 'iMessage'")
            .andWhere("message.text IS NOT NULL");

        // Add date restraints
        if (after)
            query.andWhere("message.date >= :after", {
                after: convertDateTo2001Time(after)
            });
        if (before)
            query.andWhere("message.date < :before", {
                before: convertDateTo2001Time(before)
            });

        // Add pagination params
        query.orderBy("message.date", "DESC");
        query.offset(offset);
        query.limit(limit);

        const messages = await query.getMany();
        return messages;
    }

    /**
     * Gets all messages associated with a chat
     *
     * @param chat The chat to get the messages from
     * @param offset The offset to start getting the messages from
     * @param limit The max number of messages to return
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getMessageCount(
        after?: Date,
        before?: Date
    ) {
        // Get messages with sender and the chat it's from
        const query = this.db
            .getRepository(Message)
            .createQueryBuilder("message")

        // Add default WHERE clauses
        query
            .andWhere("message.service == 'iMessage'")
            .andWhere("message.text IS NOT NULL")
            .andWhere("associated_message_type == 0");

        // Add date restraints
        if (after)
            query.andWhere("message.date >= :after", {
                after: convertDateTo2001Time(after)
            });
        if (before)
            query.andWhere("message.date < :before", {
                before: convertDateTo2001Time(before)
            });

        // Add pagination params
        query.orderBy("message.date", "DESC");

        const count = await query.getCount();
        return count;
    }

    /**
     * Gets all messages associated with a chat
     *
     * @param chat The chat to get the messages from
     * @param offset The offset to start getting the messages from
     * @param limit The max number of messages to return
     * @param after The earliest date to get messages from
     * @param before The latest date to get messages from
     */
    async getChatMessageCounts(chatStyle: "group" | "individual") {
        // Get messages with sender and the chat it's from
        const result = await this.db.getRepository(Chat).query(
            `SELECT
                chat.chat_identifier AS chat_identifier,
                chat.display_name AS group_name,
                COUNT(message.ROWID) AS message_count
            FROM chat
            JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
            JOIN message ON message.ROWID = cmj.message_id
            WHERE chat.style = ?
            GROUP BY chat.guid;`,
            [(chatStyle === "group" ? 43 : 45)]
        );

        return result;
    }
}
