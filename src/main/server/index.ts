import { app } from "electron";
import { createConnection, Connection } from "typeorm";
import * as io from "socket.io";

import { DatabaseRepository } from "./api/imessage";

// Create the database and the connection to it
export const createDbConnection = async (): Promise<Connection> => {
    return createConnection({
        type: "sqlite",
        database: `${app.getPath("userData")}/config.db`,
        entities: [`${__dirname}/entity/*.ts`],
        synchronize: true,
        logging: false
    });
};

export const createSockets = (
    db: Connection,
    repo: DatabaseRepository
): io.Server => {
    const server = io(9000);

    /**
     * Handle all other data requests
     */
    server.on("connection", async (socket) => {
        console.log("client connected");

        /**
         * Get all chats
         */
        socket.on("get-chats", async (params, send_response) => {
            const chats = await repo.getChats(null, true);

            if (send_response) send_response(null, chats);
            else socket.emit("chats", chats);
        });

        /**
         * Get messages in a chat
         */
        socket.on("get-chat-messages", async (params, send_response) => {
            if (!params?.identifier)
                if (send_response) send_response(null, "ERROR: No Identifier");
                else socket.emit("error", "ERROR: No Identifier");

            const chats = await repo.getChats(params?.identifier, true);
            const messages = await repo.getMessages(
                chats[0],
                params?.offset || 0,
                params?.limit || 100,
                params?.after,
                params?.before
            );

            if (send_response) send_response(null, messages);
            else socket.emit("messages", messages);
        });

        /**
         * Get last message in a chat
         */
        socket.on("get-last-chat-message", async (params, send_response) => {
            if (!params?.identifier)
                if (send_response) send_response(null, "ERROR: No Identifier");
                else socket.emit("error", "ERROR: No Identifier");

            const chats = await repo.getChats(params?.identifier, true);
            const messages = await repo.getMessages(chats[0], 0, 1);

            if (send_response) send_response(null, messages);
            else socket.emit("last-chat-message", messages);
        });

        // /**
        //  * Get participants in a chat
        //  */
        socket.on("get-participants", async (params, send_response) => {
            if (!params?.identifier)
                if (send_response) send_response(null, "ERROR: No Identifier");
                else socket.emit("error", "ERROR: No Identifier");

            const chats = await repo.getChats(params?.identifier, true);

            if (send_response) send_response(null, chats[0].participants);
            else socket.emit("participants", chats[0].participants);
        });

        /**
         * Send message
         */
        socket.on("send-message", async (params, send_response) => {
            console.warn("Not Implemented: Message send request");
        });

        // /**
        //  * Send reaction
        //  */
        socket.on("send-reaction", async (params, send_response) => {
            console.warn("Not Implemented: Reaction send request");
        });

        // /**
        //  * Create conversation
        //  */
        // socket.on("create-conversation", (params, send_response) => {
        //     cb({ chats: [] });
        // });

        // /**
        //  * Remove conversation
        //  */
        // socket.on("delete-conversation", (params, send_response) => {
        //     cb({ chats: [] });
        // });

        // /**
        //  * Change chat name
        //  */
        // socket.on("edit-chat-name", (params, send_response) => {
        //     cb({ chats: [] });
        // });

        // /**
        //  * Add participant to chat
        //  */
        // socket.on("add-participant", (params, send_response) => {
        //     cb({ chats: [] });
        // });

        socket.on("disconnect", () => {
            console.log("Got disconnect!");
        });
    });

    return server;
};
