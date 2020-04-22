/* eslint-disable no-param-reassign */
import { createConnection, Connection } from "typeorm";

import { convertDateTo2001Time } from "@server/api/imessage/helpers/dateUtil";
import { Chat } from "@server/api/imessage/entity/Chat";
import { Handle } from "@server/api/imessage/entity/Handle";
import { Message } from "@server/api/imessage/entity/Message";

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
            entities: [Chat, Handle, Message],
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
    async getChats(identifier?: string, withParticipants = true) {
        const query = this.db.getRepository(Chat).createQueryBuilder("chat");

        if (withParticipants)
            query.leftJoinAndSelect("chat.participants", "handle");

        // Add default WHERE clauses
        query.andWhere("chat.service_name == 'iMessage'");
        if (identifier)
            query.andWhere("chat.chat_identifier == :identifier", {
                identifier
            });
        console.log(query.getSql());

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
        chat: Chat,
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
                `message.ROWID == message_id AND chat.ROWID == chat_id${
                    chat ? " AND chat.chat_identifier == :identifier" : ""
                }`,
                { identifier: chat?.chatIdentifier || null }
            );

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
}
