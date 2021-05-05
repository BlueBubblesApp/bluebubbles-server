// NPM Package imports
import { createConnection, Connection } from "typeorm";

// All the plugin scaffolding & types
import { IPluginConfig, IPluginTypes, PluginConstructorParams } from "@server/plugins/types";
import { MessagesDbPluginBase } from "@server/plugins/messages_api/base";
import {
    AttachmentSpec,
    ChatSpec,
    HandleSpec,
    MessageSpec,
    GetAttachmentsParams,
    GetChatsParams,
    GetHandlesParams,
    GetMessagesParams
} from "@server/plugins/messages_api/types";

// All the custom plugin imports
import { Chat } from "./entity/Chat";
import { Handle } from "./entity/Handle";
import { Message } from "./entity/Message";
import { Attachment } from "./entity/Attachment";
import { convertDateTo2001Time } from "./helpers/dateUtil";

// Your plugin configuration
const configuration: IPluginConfig = {
    name: "default",
    type: IPluginTypes.MESSAGES_DB,
    displayName: "Default Messages API",
    description: "This is the default Messages Database for BlueBubbles",
    version: 1,
    properties: []
};

export default class DefaultMessagesDb extends MessagesDbPluginBase {
    db: Connection = null;

    constructor(args: PluginConstructorParams) {
        super(args);

        // Set it after the fact due to class vars
        this.config = configuration;
    }

    async connect(): Promise<void> {
        this.db = await createConnection({
            name: "iMessage",
            type: "better-sqlite3",
            database: `${process.env.HOME}/Library/Messages/chat.db`,
            entities: [Chat, Handle, Message, Attachment]
        });
    }

    async disconnect(): Promise<void> {
        await this.db.close();
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
    }: GetChatsParams): Promise<ChatSpec[]> {
        const query = this.db.getRepository(Chat).createQueryBuilder("chat");

        // Inner-join because a chat must have participants
        if (withHandles) query.innerJoinAndSelect("chat.participants", "handle");

        // Left-join because a chat may or may not have any messages
        if (withMessages) query.leftJoinAndSelect("chat.messages", "message");

        // Add default WHERE clauses
        if (!includeSms) query.andWhere("chat.service_name = 'iMessage'");
        if (!includeArchived) query.andWhere("chat.is_archived = 0");
        if (guid) query.andWhere("chat.guid = :guid", { guid });

        // Set page params
        query.offset(offset);
        if (limit) query.limit(limit);

        // Get results
        const chats = await query.getMany();
        return chats;
    }

    /**
     * Get a single chat
     *
     * @param guid A specific chat identifier to get
     */
    async getChat(guid: string, params: GetChatsParams): Promise<ChatSpec> {
        const query = { ...params };
        query.guid = guid;
        query.limit = 1;
        const chats = await this.getChats(query);
        return chats.length > 0 ? chats[0] : null;
    }

    /**
     * Gets all messages for a chat
     *
     * @param guid A specific chat identifier to get
     */
    async getChatMessages(guid: string, params: GetMessagesParams): Promise<MessageSpec[]> {
        const query = { ...params };
        query.chatGuid = guid;
        return this.getMessages(query);
    }

    /**
     * Gets all participants in a chat
     *
     * @param guid A specific chat identifier to get
     */
    async getChatParticipants(guid: string): Promise<HandleSpec[]> {
        const query = this.db.getRepository(Handle).createQueryBuilder("handle");

        // Inner-join because a handle may or may not have a chat technically
        query.leftJoinAndSelect("handle.chats", "chat");

        // Add in the param for the chat GUID
        query.andWhere("chat.guid = :guid", { guid });

        // Get results
        return query.getMany();
    }

    /**
     * Gets the last message for a given chat
     *
     * @param guid A specific chat identifier to get
     */
    async getChatLastMessage(guid: string): Promise<MessageSpec> {
        const query: GetMessagesParams = {
            chatGuid: guid,
            limit: 1,
            sort: "DESC",
            withHandle: true,
            withChats: true,
            withAttachments: true
        };

        const messages = await this.getMessages(query);
        return messages.length > 0 ? messages[0] : null;
    }
    // getChatLastMessage?(guid: string): Promise<MessageSpec>;

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
    }: GetMessagesParams): Promise<MessageSpec[]> {
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
    }: GetMessagesParams): Promise<MessageSpec[]> {
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
     * Get a single chat
     *
     * @param guid A specific chat identifier to get
     */
    async getMessage(guid: string, params: GetMessagesParams): Promise<MessageSpec> {
        const query = { ...params };
        query.guid = guid;
        query.limit = 1;
        const messages = await this.getMessages(query);
        return messages.length > 0 ? messages[0] : null;
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
    }: GetHandlesParams): Promise<HandleSpec[]> {
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
     * Get a single handle
     *
     * @param guid A specific chat identifier to get
     */
    async getHandle(address: string, params: GetHandlesParams): Promise<HandleSpec> {
        const query = { ...params };
        query.address = address;
        query.limit = 1;
        const handles = await this.getHandles(query);
        return handles.length > 0 ? handles[0] : null;
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
    }: GetAttachmentsParams): Promise<AttachmentSpec[]> {
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

    /**
     * Get a single attachment
     *
     * @param guid A specific attachment GUID to get
     */
    async getAttachment(guid: string, params: GetAttachmentsParams): Promise<AttachmentSpec> {
        const query = { ...params };
        query.guid = guid;
        query.limit = 1;
        const attachments = await this.getAttachments(query);
        return attachments.length > 0 ? attachments[0] : null;
    }
}

//     /**
//      * Get participants of a chat, in order of being added.
//      * This is a weird method because of the way SQLite will auto-sort
//      *
//      * @param identifier A specific chat identifier to get
//      */
//     async getParticipantOrder(chatROWID: number) {
//         const query = await this.db.query("SELECT * FROM chat_handle_join");

//         // We have to do manual filtering in order to maintain the order
//         // SQLite will auto-sort results if there is no Primary Key (which there isn't)
//         return query.filter((item: { chat_id: number; handle_id: number }) => item.chat_id === chatROWID);
//     }

//     /**
//      * Get all the chats from the DB
//      *
//      * @param attachmentGuid A specific attachment identifier to get
//      * @param withMessages Whether to include the participants or not
//      */
//     async getAttachment(attachmentGuid: string, withMessages = false) {
//         const query = this.db.getRepository(Attachment).createQueryBuilder("attachment");

//         if (withMessages) query.leftJoinAndSelect("attachment.messages", "message");

//         // Format the attachment GUID if it has weird additional characters
//         let actualGuid = attachmentGuid;

//         // If the attachment GUID starts with "at_", strip it out basically
//         // It can be `at_0`, at_1`, etc. So we need to get the 3rd index, `at_0_GUID`
//         if (actualGuid.includes("at_")) {
//             // eslint-disable-next-line prefer-destructuring
//             actualGuid = actualGuid.split("_")[2];
//         }

//         // Sometimes attachments have a `/` or `:` in it. If so, we want to get the actual GUID from it
//         // `i.e. p:/GUID`
//         if (actualGuid.includes("/")) {
//             // eslint-disable-next-line prefer-destructuring
//             actualGuid = actualGuid.split("/")[1];
//         }
//         if (actualGuid.includes(":")) {
//             // eslint-disable-next-line prefer-destructuring
//             actualGuid = actualGuid.split(":")[1];
//         }

//         query.andWhere("attachment.guid LIKE :guid", { guid: `%${actualGuid}` });

//         const attachment = await query.getOne();
//         return attachment;
//     }

//     /**
//      * Get all the handles from the DB
//      *
//      * @param handle Get a specific handle from the DB
//      */
//     async getHandles(handle: string = null) {
//         const repo = this.db.getRepository(Handle);
//         let handles = [];

//         // Get all handles or just get one handle
//         if (handle) {
//             handles = await repo.find({ id: handle });
//         } else {
//             handles = await repo.find();
//         }

//         return handles;
//     }

//     /**
//      * Gets all messages associated with a chat
//      *
//      * @param chat The chat to get the messages from
//      * @param offset The offset to start getting the messages from
//      * @param limit The max number of messages to return
//      * @param after The earliest date to get messages from
//      * @param before The latest date to get messages from
//      */
//     async getMessages({
//         chatGuid = null,
//         offset = 0,
//         limit = 100,
//         after = null,
//         before = null,
//         withChats = false,
//         withAttachments = true,
//         withHandle = true,
//         sort = "DESC",
//         withSMS = false,
//         where = [
//             {
//                 statement: "message.service = 'iMessage'",
//                 args: null
//             },
//             {
//                 statement: "message.text IS NOT NULL",
//                 args: null
//             }
//         ]
//     }: DBMessageParams) {
//         // Sanitize some params
//         if (after && typeof after === "number") after = new Date(after);
//         if (before && typeof before === "number") before = new Date(before);

//         // Get messages with sender and the chat it's from
//         const query = this.db.getRepository(Message).createQueryBuilder("message");

//         if (withHandle) query.leftJoinAndSelect("message.handle", "handle");

//         if (withAttachments)
//             query.leftJoinAndSelect(
//                 "message.attachments",
//                 "attachment",
//                 "message.ROWID = message_attachment.message_id AND " +
//                     "attachment.ROWID = message_attachment.attachment_id"
//             );

//         // Inner-join because all messages will have a chat
//         if (chatGuid) {
//             query
//                 .innerJoinAndSelect(
//                     "message.chats",
//                     "chat",
//                     "message.ROWID = message_chat.message_id AND chat.ROWID = message_chat.chat_id"
//                 )
//                 .andWhere("chat.guid = :guid", { guid: chatGuid });
//         } else if (withChats) {
//             query.innerJoinAndSelect(
//                 "message.chats",
//                 "chat",
//                 "message.ROWID = message_chat.message_id AND chat.ROWID = message_chat.chat_id"
//             );
//         }

//         // Add date restraints
//         if (after)
//             query.andWhere("message.date >= :after", {
//                 after: convertDateTo2001Time(after as Date)
//             });
//         if (before)
//             query.andWhere("message.date < :before", {
//                 before: convertDateTo2001Time(before as Date)
//             });

//         if (where && where.length > 0) {
//             // If withSMS is enabled, remove any statements specifying the message service
//             if (withSMS) {
//                 where = where.filter(item => item.statement !== `message.service = 'iMessage'`);
//             }

//             for (const item of where) {
//                 query.andWhere(item.statement, item.args);
//             }
//         }

//         // Add pagination params
//         query.orderBy("message.date", sort);
//         query.offset(offset);
//         query.limit(limit);

//         const messages = await query.getMany();
//         return messages;
//     }

//     /**
//      * Gets all messages that have been updated
//      *
//      * @param chat The chat to get the messages from
//      * @param offset The offset to start getting the messages from
//      * @param limit The max number of messages to return
//      * @param after The earliest date to get messages from
//      * @param before The latest date to get messages from
//      */
//     async getUpdatedMessages({
//         chatGuid = null,
//         offset = 0,
//         limit = 100,
//         after = null,
//         before = null,
//         withChats = false,
//         sort = "DESC",
//         where = []
//     }: DBMessageParams) {
//         // Sanitize some params
//         if (after && typeof after === "number") after = new Date(after);
//         if (before && typeof before === "number") before = new Date(before);

//         // Get messages with sender and the chat it's from
//         const query = this.db
//             .getRepository(Message)
//             .createQueryBuilder("message")
//             .leftJoinAndSelect("message.handle", "handle");

//         // Inner-join because all messages will have a chat
//         if (chatGuid) {
//             query
//                 .innerJoinAndSelect(
//                     "message.chats",
//                     "chat",
//                     "message.ROWID == message_chat.message_id AND chat.ROWID == message_chat.chat_id"
//                 )
//                 .andWhere("chat.guid = :guid", { guid: chatGuid });
//         } else if (withChats) {
//             query.innerJoinAndSelect(
//                 "message.chats",
//                 "chat",
//                 "message.ROWID == message_chat.message_id AND chat.ROWID == message_chat.chat_id"
//             );
//         }

//         // Add default WHERE clauses
//         query.andWhere("message.service == 'iMessage'");

//         // Add any custom WHERE clauses
//         if (where && where.length > 0) for (const item of where) query.andWhere(item.statement, item.args);

//         // Add date_delivered constraints
//         if (after)
//             query.andWhere("message.date_delivered >= :after", {
//                 after: convertDateTo2001Time(after as Date)
//             });
//         if (before)
//             query.andWhere("message.date_delivered < :before", {
//                 before: convertDateTo2001Time(before as Date)
//             });

//         // Add date_read constraints
//         if (after)
//             query.orWhere("message.date_read >= :after", {
//                 after: convertDateTo2001Time(after as Date)
//             });
//         if (before)
//             query.andWhere("message.date_read < :before", {
//                 before: convertDateTo2001Time(before as Date)
//             });

//         // Add any custom WHERE clauses
//         // We have to do this here so that it matches both before the OR and after the OR
//         if (where && where.length > 0) for (const item of where) query.andWhere(item.statement, item.args);

//         // Add pagination params
//         query.orderBy("message.date", sort);
//         query.offset(offset);
//         query.limit(limit);

//         const messages = await query.getMany();
//         return messages;
//     }

//     /**
//      * Gets message counts associated with a chat
//      *
//      * @param after The earliest date to get messages from
//      * @param before The latest date to get messages from
//      */
//     async getMessageCount(after?: Date, before?: Date, isFromMe = false) {
//         // Get messages with sender and the chat it's from
//         const query = this.db.getRepository(Message).createQueryBuilder("message");

//         // Add default WHERE clauses
//         query
//             .andWhere("message.service == 'iMessage'")
//             .andWhere("message.text IS NOT NULL")
//             .andWhere("associated_message_type == 0");

//         if (isFromMe) query.andWhere("message.is_from_me = 1");

//         // Add date restraints
//         if (after)
//             query.andWhere("message.date >= :after", {
//                 after: convertDateTo2001Time(after)
//             });
//         if (before)
//             query.andWhere("message.date < :before", {
//                 before: convertDateTo2001Time(before)
//             });

//         // Add pagination params
//         query.orderBy("message.date", "DESC");

//         const count = await query.getCount();
//         return count;
//     }

//     /**
//      * Count messages associated with different chats
//      *
//      * @param chatStyle Whether you are fetching the count for a group or individual chat
//      */
//     async getChatMessageCounts(chatStyle: "group" | "individual") {
//         // Get messages with sender and the chat it's from
//         const result = await this.db.getRepository(Chat).query(
//             `SELECT
//                 chat.chat_identifier AS chat_identifier,
//                 chat.display_name AS group_name,
//                 COUNT(message.ROWID) AS message_count
//             FROM chat
//             JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
//             JOIN message ON message.ROWID = cmj.message_id
//             WHERE chat.style = ?
//             GROUP BY chat.guid;`,
//             [chatStyle === "group" ? 43 : 45]
//         );

//         return result;
//     }

//     /**
//      * Count messages associated with different chats
//      *
//      * @param chatStyle Whether you are fetching the count for a group or individual chat
//      */
//     async getChatImageCounts() {
//         // Get messages with sender and the chat it's from
//         const result = await this.db.getRepository(Chat).query(
//             `SELECT
//                 chat.chat_identifier AS chat_identifier,
//                 chat.display_name AS group_name,
//                 COUNT(attachment.ROWID) AS image_count
//             FROM chat
//             JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
//             JOIN message ON message.ROWID = cmj.message_id
//             JOIN message_attachment_join AS maj ON message.ROWID = maj.message_id
//             JOIN attachment ON attachment.ROWID = maj.attachment_id
//             WHERE attachment.mime_type LIKE 'image%'
//             GROUP BY chat.guid;`
//         );

//         return result;
//     }

//     /**
//      * Count messages associated with different chats
//      *
//      * @param chatStyle Whether you are fetching the count for a group or individual chat
//      */
//     async getChatVideoCounts() {
//         // Get messages with sender and the chat it's from
//         const result = await this.db.getRepository(Chat).query(
//             `SELECT
//                 chat.chat_identifier AS chat_identifier,
//                 chat.display_name AS group_name,
//                 COUNT(attachment.ROWID) AS video_count
//             FROM chat
//             JOIN chat_message_join AS cmj ON chat.ROWID = cmj.chat_id
//             JOIN message ON message.ROWID = cmj.message_id
//             JOIN message_attachment_join AS maj ON message.ROWID = maj.message_id
//             JOIN attachment ON attachment.ROWID = maj.attachment_id
//             WHERE attachment.mime_type LIKE 'video%'
//             GROUP BY chat.guid;`
//         );

//         return result;
//     }

//     /**
//      * Gets message counts associated with a chat
//      *
//      * @param after The earliest date to get messages from
//      * @param before The latest date to get messages from
//      */
//     async getAttachmentCount() {
//         // Get messages with sender and the chat it's from
//         const query = this.db.getRepository(Attachment).createQueryBuilder("attachment");

//         const count = await query.getCount();
//         return count;
//     }
// }
