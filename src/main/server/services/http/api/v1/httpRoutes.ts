import * as KoaRouter from "koa-router";

// Middleware
import { AuthMiddleware } from "./middleware/authMiddleware";

// Routers
import { ThemeRouter } from "./routers/themeRouter";
import { HandleRouter } from "./routers/handleRouter";
import { MessageRouter } from "./routers/messageRouter";
import { ChatRouter } from "./routers/chatRouter";
import { AttachmentRouter } from "./routers/attachmentRouter";
import { FcmRouter } from "./routers/fcmRouter";
import { ServerRouter } from "./routers/serverRouter";
import { GeneralRouter } from "./routers/generalRouter";
import { UiRouter } from "./routers/uiRouter";
import { SettingsRouter } from "./routers/settingsRouter";
import { ContactRouter } from "./routers/contactRouter";
import { LogMiddleware } from "./middleware/logMiddleware";
import { MacOsRouter } from "./routers/macosRouter";

export class HttpRoutes {
    static ver = "/api/v1";

    private static get protected() {
        return [...this.unprotected, AuthMiddleware];
    }

    private static get unprotected() {
        return [LogMiddleware];
    }

    static createRoutes(router: KoaRouter) {
        router.get(`${this.ver}/ping`, ...this.protected, GeneralRouter.ping);

        // MacOS routes
        router.post(`${this.ver}/mac/lock`, ...this.protected, MacOsRouter.lock);

        // Server routes
        router.get(`${this.ver}/server/info`, ...this.protected, ServerRouter.getInfo);
        router.get(`${this.ver}/server/logs`, ...this.protected, ServerRouter.getLogs);
        router.get(`${this.ver}/server/update/check`, ...this.protected, ServerRouter.checkForUpdate);
        router.get(`${this.ver}/server/statistics/totals`, ...this.protected, ServerRouter.getStatTotals);
        router.get(`${this.ver}/server/statistics/media`, ...this.protected, ServerRouter.getStatMedia);
        router.get(`${this.ver}/server/statistics/media/chat`, ...this.protected, ServerRouter.getStatMediaByChat);

        // FCM routes
        router.post(`${this.ver}/fcm/device`, ...this.protected, FcmRouter.registerDevice);
        router.get(`${this.ver}/fcm/client`, ...this.protected, FcmRouter.getClientConfig);

        // Attachment Routes
        router.get(`${this.ver}/attachment/count`, ...this.protected, AttachmentRouter.count);
        router.get(`${this.ver}/attachment/:guid`, ...this.protected, AttachmentRouter.find);
        router.get(`${this.ver}/attachment/:guid/download`, ...this.protected, AttachmentRouter.download);
        router.get(`${this.ver}/attachment/:guid/blurhash`, ...this.protected, AttachmentRouter.blurhash);

        // Chat Routes
        router.post(`${this.ver}/chat/new`, ...this.protected, ChatRouter.create);
        router.get(`${this.ver}/chat/count`, ...this.protected, ChatRouter.count);
        router.post(`${this.ver}/chat/query`, ...this.protected, ChatRouter.query);
        router.get(`${this.ver}/chat/:guid/message`, ...this.protected, ChatRouter.getMessages);
        router.post(`${this.ver}/chat/:guid/participant/add`, ...this.protected, ChatRouter.addParticipant);
        router.post(`${this.ver}/chat/:guid/participant/remove`, ...this.protected, ChatRouter.removeParticipant);
        router.put(`${this.ver}/chat/:guid`, ...this.protected, ChatRouter.update);
        router.get(`${this.ver}/chat/:guid`, ...this.protected, ChatRouter.find);

        // Message Routes
        router.post(`${this.ver}/message/text`, ...this.protected, MessageRouter.sendText);
        router.post(`${this.ver}/message/attachment`, ...this.protected, MessageRouter.sendAttachment);
        router.post(`${this.ver}/message/react`, ...this.protected, MessageRouter.react);
        router.post(`${this.ver}/message/reply`, ...this.protected, MessageRouter.reply);
        router.get(`${this.ver}/message/count`, ...this.protected, MessageRouter.count);
        router.get(`${this.ver}/message/count/me`, ...this.protected, MessageRouter.sentCount);
        router.post(`${this.ver}/message/query`, ...this.protected, MessageRouter.query);
        router.get(`${this.ver}/message/:guid`, ...this.protected, MessageRouter.find);

        // Handle Routes
        router.get(`${this.ver}/handle/count`, ...this.protected, HandleRouter.count);
        router.post(`${this.ver}/handle/query`, ...this.protected, HandleRouter.query);
        router.get(`${this.ver}/handle/:guid`, ...this.protected, HandleRouter.find);

        // Contact routes
        router.get(`${this.ver}/contact`, ...this.protected, ContactRouter.get);
        router.post(`${this.ver}/contact/query`, ...this.protected, ContactRouter.query);

        // Theme routes
        router.get(`${this.ver}/backup/theme`, ...this.protected, ThemeRouter.get);
        router.post(`${this.ver}/backup/theme`, ...this.protected, ThemeRouter.create);

        // Settings routes
        router.get(`${this.ver}/backup/settings`, ...this.protected, SettingsRouter.get);
        router.post(`${this.ver}/backup/settings`, ...this.protected, SettingsRouter.create);

        // UI Routes
        router.get("/", ...this.unprotected, UiRouter.index);
    }
}
