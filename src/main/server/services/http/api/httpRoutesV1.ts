import { nativeImage } from "electron";
import * as KoaRouter from "koa-router";
import * as mime from "mime-types";
import * as fs from "fs";
import * as path from "path";
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";
import { createBadRequestResponse, createNotFoundResponse, createSuccessResponse } from "@server/helpers/responses";
import { getAttachmentResponse } from "@server/databases/imessage/entity/Attachment";
import { getChatResponse } from "@server/databases/imessage/entity/Chat";
import { getMessageResponse } from "@server/databases/imessage/entity/Message";
import { getHandleResponse, Handle } from "@server/databases/imessage/entity/Handle";
import { DBMessageParams } from "@server/databases/imessage/types";
import { HandleResponse, MessageResponse } from "@server/types";
import { MessagesBasePath } from "../constants";
import { parseQuality, parseNumber } from "../helpers";
import { AuthMiddleware } from "../middleware/authMiddleware";
import { GeneralRepo } from "../repo/generalRepo";

export class HttpRoutesV1 {
    static ver = "/api/v1";

    static createRoutes(router: KoaRouter) {
        // Misc routes
        router.get(`${this.ver}/ping`, AuthMiddleware, async (ctx, _) => {
            ctx.status = 200;
            ctx.body = { message: "pong" };
        });
        router.get(`${this.ver}/server/info`, AuthMiddleware, async (ctx, _) => {
            ctx.status = 200;
            ctx.body = createSuccessResponse(GeneralRepo.getServerMetadata());
        });
        router.get(`${this.ver}/server/logs`, AuthMiddleware, async (ctx, _) => {
            const countParam = ctx.request.query?.count ?? "100";
            let count;

            try {
                count = Number.parseInt(countParam as string, 10);
            } catch (ex: any) {
                count = 100;
            }

            const logs = await FileSystem.getLogs({ count });
            ctx.body = createSuccessResponse(logs);
        });

        // FCM routes
        router.post(`${this.ver}/fcm/device`, AuthMiddleware, async (ctx, _) => {
            const { body } = ctx.request;

            if (!body?.name || !body?.identifier) {
                ctx.status = 400;
                ctx.body = createBadRequestResponse("No device name or ID specified");
                return;
            }

            await GeneralRepo.addFcmDevice(body?.name, body?.identifier);
            ctx.body = createSuccessResponse(null, "Successfully added device!");
        });
        router.get(`${this.ver}/fcm/client`, AuthMiddleware, async (ctx, _) => {
            ctx.body = createSuccessResponse(FileSystem.getFCMClient(), "Successfully got FCM data");
        });

        // Attachment Routes
        router.get(`${this.ver}/attachment/:guid`, AuthMiddleware, async (ctx, _) => {
            const { guid } = ctx.params;

            // Fetch the info for the attachment by GUID
            const attachment = await Server().iMessageRepo.getAttachment(guid);
            if (!attachment) {
                ctx.status = 404;
                ctx.body = createNotFoundResponse("Attachment does not exist!");
                return;
            }

            ctx.body = createSuccessResponse(await getAttachmentResponse(attachment));
        });
        router.get(`${this.ver}/attachment/:guid/download`, AuthMiddleware, async (ctx, _) => {
            const { guid } = ctx.params;
            // const { height, width, quality } = ctx.request.query;

            // Fetch the info for the attachment by GUID
            const attachment = await Server().iMessageRepo.getAttachment(guid);
            if (!attachment) {
                ctx.status = 404;
                ctx.body = createNotFoundResponse("Attachment does not exist!");
                return;
            }

            const aPath = FileSystem.getRealPath(attachment.filePath);
            let mimeType = attachment.mimeType ?? mime.lookup(aPath);
            if (!mimeType) {
                mimeType = "application/octet-stream";
            }

            // // If we want to resize the image, do so here
            // if (mimeType.startsWith("image/") && mimeType !== "image/gif" && (quality || width || height)) {
            //     const opts: Partial<Electron.ResizeOptions> = {};
            //     console.log("PARSING");

            //     // Parse opts
            //     const parsedWidth = parseNumber(width as string);
            //     const parsedHeight = parseNumber(height as string);
            //     const parsedQuality = parseQuality(quality as string);

            //     let newName = attachment.transferName;
            //     if (parsedQuality) {
            //         newName += `.${parsedQuality}`;
            //         opts.quality = parsedQuality;
            //     }
            //     if (parsedHeight) {
            //         newName += `.${parsedHeight}`;
            //         opts.height = parsedHeight;
            //     }
            //     if (parsedWidth) {
            //         newName += `.${parsedWidth}`;
            //         opts.width = parsedWidth;
            //     }

            //     // See if we already have a cached attachment
            //     if (FileSystem.cachedAttachmentExists(attachment, newName)) {
            //         console.log("EXISTS");
            //         aPath = FileSystem.cachedAttachmentPath(attachment, newName);
            //     } else {
            //         console.log("DOESNt");
            //         const image = nativeImage.createFromPath(aPath);
            //         // image.resize(opts);
            //         FileSystem.saveCachedAttachment(attachment, newName, image.toBitmap());
            //         aPath = FileSystem.cachedAttachmentPath(attachment, newName);
            //     }
            // }

            const src = fs.createReadStream(aPath);
            ctx.response.set("Content-Type", mimeType as string);
            ctx.body = src;
        });
        router.get(`${this.ver}/attachment/count`, AuthMiddleware, async (ctx, _) => {
            const total = await Server().iMessageRepo.getAttachmentCount();
            ctx.body = createSuccessResponse({ total });
        });

        // Chat Routes
        router.get(`${this.ver}/chat/count`, AuthMiddleware, async (ctx, _) => {
            const chats = await Server().iMessageRepo.getChats({ withSMS: true });
            const serviceCounts: { [key: string]: number } = {};
            for (const chat of chats) {
                if (!Object.keys(serviceCounts).includes(chat.serviceName)) {
                    serviceCounts[chat.serviceName] = 0;
                }

                serviceCounts[chat.serviceName] += 1;
            }

            ctx.body = createSuccessResponse({
                total: chats.length,
                breakdown: serviceCounts
            });
        });
        router.post(`${this.ver}/chat/query`, AuthMiddleware, async (ctx, _) => {
            const { body } = ctx.request;

            // Pull out the filters
            const withQuery = (body?.with ?? [])
                .filter((e: any) => typeof e === "string")
                .map((e: string) => e.toLowerCase().trim());
            const withParticipants = withQuery.includes("participants");
            const withLastMessage = withQuery.includes("lastmessage");
            const withSMS = withQuery.includes("sms");
            const withArchived = withQuery.includes("archived");
            const guid = body?.guid;

            // Pull the pagination params and make sure they are correct
            let offset = parseNumber(body?.offset as string) ?? 0;
            let limit = parseNumber(body?.limit as string) ?? 1000;
            if (offset < 0) offset = 0;
            if (limit < 0 || limit > 1000) limit = 1000;

            const chats = await Server().iMessageRepo.getChats({
                chatGuid: guid as string,
                withSMS,
                withParticipants,
                withLastMessage,
                offset,
                limit
            });

            // If the query is with the last message, it makes the participants list 1 for each chat
            // We need to fetch all the chats with their participants, then cache the participants
            // so we can merge the participant list with the chats
            const chatCache: { [key: string]: Handle[] } = {};
            if (withLastMessage) {
                const tmpChats = await Server().iMessageRepo.getChats({
                    chatGuid: guid as string,
                    withParticipants: true,
                    withArchived,
                    withSMS,
                    offset,
                    limit
                });

                for (const chat of tmpChats) {
                    chatCache[chat.guid] = chat.participants;
                }
            }

            const results = [];
            for (const chat of chats ?? []) {
                if (chat.guid.startsWith("urn:")) continue;
                const chatRes = await getChatResponse(chat);

                if (withLastMessage) {
                    // Insert the cached participants from the original request
                    if (Object.keys(chatCache).includes(chat.guid)) {
                        chatRes.participants = await Promise.all(
                            chatCache[chat.guid].map(
                                async (e): Promise<HandleResponse> => {
                                    const test = await getHandleResponse(e);
                                    return test;
                                }
                            )
                        );
                    }

                    // Set the last message, if applicable
                    if (chatRes.messages && chatRes.messages.length > 0) {
                        [chatRes.lastMessage] = chatRes.messages;

                        // Remove the last message from the result
                        delete chatRes.messages;
                    }
                }

                results.push(chatRes);
            }

            // Build metadata to return
            const metadata = {
                total: await Server().iMessageRepo.getChatCount(),
                offset,
                limit
            };

            ctx.body = createSuccessResponse(results, null, metadata);
        });
        router.get(`${this.ver}/chat/:guid/message`, AuthMiddleware, async (ctx, _) => {
            const withQuery = ((ctx.request.query.with ?? "") as string)
                .toLowerCase()
                .split(",")
                .map(e => e.trim());
            const withAttachments = withQuery.includes("attachment") || withQuery.includes("attachments");
            const withHandle = withQuery.includes("handle") || withQuery.includes("handles");
            const withSMS = withQuery.includes("sms");
            const sort = ["DESC", "ASC"].includes(((ctx.request.query?.sort as string) ?? "").toLowerCase())
                ? ctx.request.query?.sort
                : "DESC";
            const after = ctx.request.query?.after;
            const before = ctx.request.query?.before;

            // Pull the pagination params and make sure they are correct
            let offset = parseNumber(ctx.request.query?.offset as string) ?? 0;
            let limit = parseNumber(ctx.request.query?.limit as string) ?? 100;
            if (offset < 0) offset = 0;
            if (limit < 0 || limit > 1000) limit = 1000;

            const chats = await Server().iMessageRepo.getChats({
                chatGuid: ctx.params.guid,
                withSMS: true,
                withParticipants: false
            });

            if (!chats || chats.length === 0) {
                ctx.status = 404;
                ctx.body = createNotFoundResponse("Chat does not exist!");
                return;
            }

            const opts: DBMessageParams = {
                chatGuid: ctx.params.guid,
                withAttachments,
                withHandle,
                withSMS,
                offset,
                limit,
                sort: sort as "ASC" | "DESC",
                before: Number.parseInt(before as string, 10),
                after: Number.parseInt(after as string, 10)
            };

            // Fetch the info for the message by GUID
            const messages = await Server().iMessageRepo.getMessages(opts);
            const results = [];
            for (const msg of messages ?? []) {
                results.push(await getMessageResponse(msg));
            }

            ctx.body = createSuccessResponse(results);
        });
        router.get(`${this.ver}/chat/:guid`, AuthMiddleware, async (ctx, _) => {
            const withQuery = ((ctx.request.query.with ?? "") as string)
                .toLowerCase()
                .split(",")
                .map(e => e.trim());
            const withParticipants = withQuery.includes("participants");
            const withLastMessage = withQuery.includes("lastmessage");

            const chats = await Server().iMessageRepo.getChats({
                chatGuid: ctx.params.guid,
                withSMS: true,
                withParticipants
            });

            if (!chats || chats.length === 0) {
                ctx.status = 404;
                ctx.body = createNotFoundResponse("Chat does not exist!");
                return;
            }

            const res = await getChatResponse(chats[0]);
            if (withLastMessage) {
                res.lastMessage = await getMessageResponse(
                    await Server().iMessageRepo.getChatLastMessage(ctx.params.guid)
                );
            }

            ctx.body = createSuccessResponse(res);
        });

        // Message Routes
        router.get(`${this.ver}/message/count`, AuthMiddleware, async (ctx, _) => {
            const total = await Server().iMessageRepo.getMessageCount();
            ctx.body = createSuccessResponse({ total });
        });
        router.get(`${this.ver}/message/count/me`, AuthMiddleware, async (ctx, _) => {
            const total = await Server().iMessageRepo.getMessageCount(null, null, true);
            ctx.body = createSuccessResponse({ total });
        });
        router.post(`${this.ver}/message/query`, AuthMiddleware, async (ctx, _) => {
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

                const msgRes = await getMessageResponse(msg, false);
                results.push(msgRes);
            }

            // Build metadata to return
            const metadata = {
                offset,
                limit
            };

            ctx.body = createSuccessResponse(results, null, metadata);
        });
        router.get(`${this.ver}/message/:guid`, AuthMiddleware, async (ctx, _) => {
            const { guid } = ctx.params;
            const withQuery = ((ctx.request.query.with ?? "") as string)
                .toLowerCase()
                .split(",")
                .map(e => e.trim());
            const withChats = withQuery.includes("chats") || withQuery.includes("chat");
            const withParticipants =
                withQuery.includes("chats.participants") || withQuery.includes("chat.participants");

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
        });

        // Handle Routes
        router.get(`${this.ver}/handle/count`, AuthMiddleware, async (ctx, _) => {
            const total = await Server().iMessageRepo.getHandleCount();
            ctx.body = createSuccessResponse({ total });
        });
        router.get(`${this.ver}/handle/:guid`, AuthMiddleware, async (ctx, _) => {
            const handles = await Server().iMessageRepo.getHandles(ctx.params.guid);
            if (!handles || handles.length === 0) {
                ctx.status = 404;
                ctx.body = createNotFoundResponse("Handle does not exist!");
                return;
            }

            ctx.body = createSuccessResponse(await getHandleResponse(handles[0]));
        });

        // Landing page
        router.get("/", async (ctx, _) => {
            ctx.status = 200;
            ctx.body = `
                <html>
                    <title>BlueBubbles Server</title>
                    <body>
                        <h4>Welcome to the BlueBubbles Server landing page!</h4>
                    </body>
                </html>
            `;
        });
    }
}
