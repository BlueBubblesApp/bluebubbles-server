import { app, dialog, ipcMain, systemPreferences } from "electron";
import { askForAccessibilityAccess, askForFullDiskAccess } from "node-mac-permissions";
import process from "process";

import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { AlertsInterface } from "@server/api/v1/interfaces/alertsInterface";
import { openLogs, openAppData } from "@server/api/v1/apple/scripts";
import { fixServerUrl } from "@server/helpers/utils";
import { ContactInterface } from "@server/api/v1/interfaces/contactInterface";
import { BlueBubblesHelperService } from "../privateApi";
import { getContactPermissionStatus, requestContactPermission } from "@server/utils/PermissionUtils";
import { ScheduledMessagesInterface } from "@server/api/v1/interfaces/scheduledMessagesInterface";
import { ChatInterface } from "@server/api/v1/interfaces/chatInterface";

export class IPCService {
    /**
     * Starts configuration related inter-process-communication handlers.
     */
    static startIpcListeners() {
        ipcMain.handle("set-config", async (_, args) => {
            // Make sure that the server address being sent is using https (if enabled)
            if (args.server_address) {
                args.server_address = fixServerUrl(args.server_address);
            }

            // Make sure the Ngrok key is properly formatted
            if (args.ngrok_key) {
                if (args.ngrok_key.startsWith("./ngrok")) {
                    args.ngrok_key = args.ngrok_key.replace("./ngrok", "").trim();
                }
                if (args.ngrok_key.startsWith("authtoken")) {
                    args.ngrok_key = args.ngrok_key.replace("authtoken", "").trim();
                }
                args.ngrok_key = args.ngrok_key.trim();
            }

            // If we are changing the proxy service to a non-dyn dns service, we need to make sure "use https" is off
            if (args.proxy_service && args.proxy_service !== "dynamic-dns") {
                const httpsStatus = (args.use_custom_certificate ??
                    Server().repo.getConfig("use_custom_certificate")) as boolean;
                if (httpsStatus) {
                    Server().repo.setConfig("use_custom_certificate", false);
                }
            }

            for (const item of Object.keys(args)) {
                if (Server().repo.hasConfig(item) && Server().repo.getConfig(item) !== args[item]) {
                    Server().repo.setConfig(item, args[item]);
                }
            }

            return Server().repo?.config;
        });

        ipcMain.handle("get-config", async (_, __) => {
            if (!Server().repo.db) return {};
            return Server().repo?.config;
        });

        ipcMain.handle("get-alerts", async (_, __) => {
            const alerts = await AlertsInterface.find();
            return alerts;
        });

        ipcMain.handle("mark-alerts-as-read", async (_, args) => {
            await AlertsInterface.markAsRead(args);
        });

        ipcMain.handle("set-fcm-server", async (_, args) => {
            FileSystem.saveFCMServer(args);
            if (!Server().fcm) {
                Server().initFcm();
                await Server().fcm.start();
            } else {
                await Server().fcm.restart();
            }
        });

        ipcMain.handle("set-fcm-client", async (_, args) => {
            FileSystem.saveFCMClient(args);
            if (!Server().fcm) {
                Server().initFcm();
                await Server().fcm.start();
            } else {
                await Server().fcm.restart();
            }
        });

        ipcMain.handle("get-devices", async (event, args) => {
            return await Server().repo.devices().find();
        });

        ipcMain.handle("get-private-api-requirements", async (_, __) => {
            return await Server().checkPrivateApiRequirements();
        });

        ipcMain.handle("get-private-api-status", async (_, __) => {
            return {
                enabled: Server().repo.getConfig("enable_private_api") as boolean,
                connected: !!Server().privateApiHelper?.helper,
                port: BlueBubblesHelperService.port
            };
        });

        ipcMain.handle("reinstall-helper-bundle", async (_, __) => {
            return await BlueBubblesHelperService.installBundle(true);
        });

        ipcMain.handle("get-fcm-server", (event, args) => {
            return FileSystem.getFCMServer();
        });

        ipcMain.handle("get-fcm-client", (event, args) => {
            return FileSystem.getFCMClient();
        });

        ipcMain.handle("get-webhooks", async (event, args) => {
            const res = await Server().repo.getWebhooks();
            return res.map(e => ({ id: e.id, url: e.url, events: e.events, created: e.created }));
        });

        ipcMain.handle("create-webhook", async (event, payload) => {
            const res = await Server().repo.addWebhook(payload.url, payload.events);
            const output = { id: res.id, url: res.url, events: res.events, created: res.created };
            return output;
        });

        ipcMain.handle("delete-webhook", async (event, args) => {
            return await Server().repo.deleteWebhook({ url: args.url, id: args.id });
        });

        ipcMain.handle("update-webhook", async (event, args) => {
            return await Server().repo.updateWebhook({ id: args.id, url: args?.url, events: args?.events });
        });

        ipcMain.handle("contact-permission-status", async (event, _) => {
            return await getContactPermissionStatus();
        });

        ipcMain.handle("request-contact-permission", async (event, _) => {
            return await requestContactPermission();
        });

        ipcMain.handle("get-contacts", async (event, extraProperties) => {
            return await ContactInterface.getAllContacts(extraProperties ?? []);
        });

        ipcMain.handle("delete-contacts", async (event, _) => {
            return await ContactInterface.deleteAllContacts();
        });

        ipcMain.handle("add-contact", async (event, args) => {
            return await ContactInterface.createContact({
                firstName: args?.firstName ?? "",
                lastName: args?.lastName ?? "",
                displayName: args?.displayName ?? "",
                emails: args.emails ?? [],
                phoneNumbers: args.phoneNumbers ?? []
            });
        });

        ipcMain.handle("update-contact", async (event, args) => {
            return await ContactInterface.createContact({
                id: args.contactId ?? args.id,
                firstName: args?.firstName ?? "",
                lastName: args.lastName ?? "",
                displayName: args?.displayName ?? "",
                emails: args.emails ?? [],
                phoneNumbers: args.phoneNumbers ?? [],
                updateEntry: true
            });
        });

        ipcMain.handle("remove-contact", async (event, id) => {
            return await ContactInterface.deleteContact({ contactId: id });
        });

        ipcMain.handle("remove-address", async (event, id) => {
            return await ContactInterface.deleteContactAddress({ contactAddressId: id });
        });

        ipcMain.handle("add-address", async (event, args) => {
            return await ContactInterface.addAddressToContactById(args.contactId, args.address, args.type);
        });

        ipcMain.handle("import-vcf", async (event, path) => {
            return await ContactInterface.importFromVcf(path);
        });

        ipcMain.handle("toggle-tutorial", async (_, toggle) => {
            await Server().repo.setConfig("tutorial_is_done", toggle);

            if (toggle) {
                await Server().hotRestart();
            }
        });

        ipcMain.handle("get-message-count", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getMessageCount({
                after: args?.after,
                before: args?.before,
                isFromMe: args?.isFromMe
            });
            return count;
        });

        ipcMain.handle("get-chat-image-count", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "image" });
            return count;
        });

        ipcMain.handle("get-chat-video-count", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "video" });
            return count;
        });

        ipcMain.handle("get-group-message-counts", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getChatMessageCounts("group");
            return count;
        });

        ipcMain.handle("get-individual-message-counts", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getChatMessageCounts("individual");
            return count;
        });

        ipcMain.handle("get-best-friend", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const counts = await Server().iMessageRepo.getChatMessageCounts("individual");

            let currentTopCount = 0;
            let currentTop: string | null = null;
            let isGroup = false;
            counts.forEach((item: any) => {
                if (!currentTop || item.message_count > currentTopCount) {
                    const guid = item.chat_guid.replace("iMessage", "").replace(";+;", "").replace(";-;", "");
                    currentTopCount = item.message_count;
                    isGroup = (item.group_name ?? "").length > 0;
                    currentTop = isGroup ? item.group_name : guid;
                }
            });

            // If we don't get a top , return "Unknown"
            if (!currentTop) return "Unknown";

            // If this is an individual, get their contact info
            if (!isGroup) {
                try {
                    const res = await ContactInterface.queryContacts([currentTop]);
                    const contact = res && res.length > 0 ? res[0] : null;
                    if (contact?.displayName) {
                        return contact.displayName;
                    }
                } catch {
                    // Don't do anything if we fail. The fallback will be applied
                }
            } else if ((currentTop as string).length === 0) {
                return "Unnamed Group";
            }

            return currentTop;
        });

        ipcMain.handle("refresh-api-contacts", async (_, __) => {
            ContactInterface.refreshApiContacts();
        });

        ipcMain.handle("check-permissions", async (_, __) => {
            return await Server().checkPermissions();
        });

        ipcMain.handle("prompt_accessibility", async (_, __) => {
            return {
                abPerms: systemPreferences.isTrustedAccessibilityClient(true) ? "authorized" : "denied"
            };
        });

        ipcMain.handle("prompt_disk_access", async (_, __) => {
            return {
                fdPerms: "authorized"
            };
        });

        ipcMain.handle("get-caffeinate-status", (_, __) => {
            return {
                isCaffeinated: Server().caffeinate.isCaffeinated,
                autoCaffeinate: Server().repo.getConfig("auto_caffeinate")
            };
        });

        ipcMain.handle("purge-event-cache", (_, __) => {
            if (Server().eventCache.size() === 0) {
                Server().log("No events to purge from event cache!");
            } else {
                Server().log(`Purging ${Server().eventCache.size()} items from the event cache!`);
                Server().eventCache.purge();
            }
        });

        ipcMain.handle("purge-devices", (_, __) => {
            Server().repo.devices().clear();
        });

        ipcMain.handle("restart-via-terminal", (_, __) => {
            Server().restartViaTerminal();
        });

        ipcMain.handle("get-binary-path", async (_, __) => {
            return process.execPath;
        });

        ipcMain.handle("hot-restart", async (_, __) => {
            await Server().hotRestart();
        });

        ipcMain.handle("full-restart", async (_, __) => {
            await Server().relaunch();
        });

        ipcMain.handle("reset-app", async (_, __) => {
            await Server().stopAll();
            FileSystem.removeDirectory(FileSystem.baseDir);
            await Server().relaunch();
        });

        ipcMain.handle("show-dialog", (_, opts: Electron.MessageBoxOptions) => {
            return dialog.showMessageBox(Server().window, opts);
        });

        ipcMain.handle("open-log-location", (_, __) => {
            FileSystem.executeAppleScript(openLogs());
        });

        ipcMain.handle("open-app-location", (_, __) => {
            FileSystem.executeAppleScript(openAppData());
        });

        ipcMain.handle("clear-alerts", async (_, __) => {
            Server().notificationCount = 0;
            app.setBadgeCount(0);
            await Server().repo.alerts().clear();
        });

        ipcMain.handle("open-fulldisk-preferences", async (_, __) => {
            askForFullDiskAccess();
        });

        ipcMain.handle("open-accessibility-preferences", async (_, __) => {
            askForAccessibilityAccess();
        });

        ipcMain.handle("get-attachment-cache-info", async (_, __) => {
            const count = await FileSystem.cachedAttachmentCount();
            const size = await FileSystem.getCachedAttachmentsSize();
            return { count, size };
        });

        ipcMain.handle("clear-attachment-caches", async (_, __) => {
            FileSystem.clearAttachmentCaches();
        });

        ipcMain.handle("delete-scheduled-message", async (_, id: number) => {
            return ScheduledMessagesInterface.deleteScheduledMessage(id);
        });

        ipcMain.handle("delete-scheduled-messages", async (_, __) => {
            return ScheduledMessagesInterface.deleteScheduledMessages();
        });

        ipcMain.handle("get-scheduled-messages", async (_, __) => {
            return ScheduledMessagesInterface.getScheduledMessages();
        });

        ipcMain.handle("create-scheduled-message", async (_, msg) => {
            return ScheduledMessagesInterface.createScheduledMessage(
                msg.type,
                msg.payload,
                new Date(msg.scheduledFor),
                msg.schedule
            );
        });

        ipcMain.handle("get-chats", async (_, msg) => {
            const [chats, __] = await ChatInterface.get({ limit: 10000 });
            return chats;
        });

        ipcMain.handle("get-oauth-url", async (_, __) => {
            return await Server().oauthService?.getOauthUrl();
        });

        ipcMain.handle("restart-oauth-service", async (_, __) => {
            if (Server().oauthService?.running) return;
            await Server().oauthService?.restart();
        });
    }
}
