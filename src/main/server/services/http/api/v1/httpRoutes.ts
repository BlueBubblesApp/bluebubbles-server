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

export class HttpRoutes {
    static ver = "/api/v1";

    static createRoutes(router: KoaRouter) {
        // Misc routes
        router.get(`${this.ver}/ping`, AuthMiddleware, GeneralRouter.ping);
        router.get(`${this.ver}/server/info`, AuthMiddleware, ServerRouter.getInfo);
        router.get(`${this.ver}/server/logs`, AuthMiddleware, ServerRouter.getLogs);
        router.get(`${this.ver}/server/update/check`, AuthMiddleware, ServerRouter.checkForUpdate);
        router.get(`${this.ver}/server/statistics/totals`, AuthMiddleware, ServerRouter.getStatTotals);
        router.get(`${this.ver}/server/statistics/media`, AuthMiddleware, ServerRouter.getStatMedia);
        router.get(`${this.ver}/server/statistics/media/chat`, AuthMiddleware, ServerRouter.getStatMediaByChat);

        // FCM routes
        router.post(`${this.ver}/fcm/device`, AuthMiddleware, FcmRouter.registerDevice);
        router.get(`${this.ver}/fcm/client`, AuthMiddleware, FcmRouter.getClientConfig);

        // Attachment Routes
        router.get(`${this.ver}/attachment/:guid`, AuthMiddleware, AttachmentRouter.find);
        router.get(`${this.ver}/attachment/:guid/download`, AuthMiddleware, AttachmentRouter.download);
        router.get(`${this.ver}/attachment/count`, AuthMiddleware, AttachmentRouter.count);

        // Chat Routes
        router.get(`${this.ver}/chat/count`, AuthMiddleware, ChatRouter.count);
        router.post(`${this.ver}/chat/query`, AuthMiddleware, ChatRouter.query);
        router.get(`${this.ver}/chat/:guid/message`, AuthMiddleware, ChatRouter.getMessages);
        router.get(`${this.ver}/chat/:guid`, AuthMiddleware, ChatRouter.find);

        // Message Routes
        router.get(`${this.ver}/message/count`, AuthMiddleware, MessageRouter.count);
        router.get(`${this.ver}/message/count/me`, AuthMiddleware, MessageRouter.sentCount);
        router.post(`${this.ver}/message/query`, AuthMiddleware, MessageRouter.query);
        router.get(`${this.ver}/message/:guid`, AuthMiddleware, MessageRouter.find);

        // Handle Routes
        router.get(`${this.ver}/handle/count`, AuthMiddleware, HandleRouter.count);
        router.get(`${this.ver}/handle/:guid`, AuthMiddleware, HandleRouter.find);

        // Theme routes
        router.get(`${this.ver}/backup/theme`, AuthMiddleware, ThemeRouter.get);
        router.post(`${this.ver}/backup/theme`, AuthMiddleware, ThemeRouter.create);

        // Settings routes
        router.get(`${this.ver}/backup/settings`, AuthMiddleware, SettingsRouter.get);
        router.post(`${this.ver}/backup/settings`, AuthMiddleware, SettingsRouter.create);

        // UI Routes
        router.get("/", UiRouter.index);
    }
}
