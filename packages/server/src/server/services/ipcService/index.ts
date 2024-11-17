import { app, dialog, ipcMain, systemPreferences, shell } from "electron";
import { askForAccessibilityAccess, askForFullDiskAccess } from "node-mac-permissions";
import process from "process";

import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { AlertsInterface } from "@server/api/interfaces/alertsInterface";
import { openLogs, openAppData } from "@server/api/apple/scripts";
import { fixServerUrl } from "@server/helpers/utils";
import { ContactInterface } from "@server/api/interfaces/contactInterface";
import { PrivateApiService } from "../../api/privateApi/PrivateApiService";
import { getContactPermissionStatus, requestContactPermission } from "@server/utils/PermissionUtils";
import { ScheduledMessagesInterface } from "@server/api/interfaces/scheduledMessagesInterface";
import { ChatInterface } from "@server/api/interfaces/chatInterface";
import { GeneralInterface } from "@server/api/interfaces/generalInterface";
import {
    isMinBigSur,
    isMinCatalina,
    isMinHighSierra,
    isMinMojave,
    isMinMonterey,
    isMinSierra,
    isMinVentura,
    isMinSonoma
} from "@server/env";
import { Loggable, getLogger } from "@server/lib/logging/Loggable";
import { ZrokManager } from "@server/managers/zrokManager";
import { ProxyServices } from "@server/databases/server/constants";

export class IPCService extends Loggable {
    tag = "IPCService";

    /**
     * Starts configuration related inter-process-communication handlers.
     */
    static startIpcListeners() {
        const log = getLogger("IPCService");

        ipcMain.handle("get-env", async (_, __) => {
            return {
                isMinSierra: isMinSierra,
                isMinHighSierra: isMinHighSierra,
                isMinMojave: isMinMojave,
                isMinCatalina: isMinCatalina,
                isMinBigSur: isMinBigSur,
                isMinMonterey: isMinMonterey,
                isMinVentura: isMinVentura,
                isMinSonoma: isMinSonoma
            };
        });

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

            // If we are changing the proxy service to a non-custom url service, we need to make sure "use https" is off
            if (args.proxy_service && ![ProxyServices.DynamicDNS, ProxyServices.LanURL].includes(args.proxy_service)) {
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
            const cfg = Server().repo?.config;
            const serverInfo = await GeneralInterface.getServerMetadata();
            return { ...cfg, ...serverInfo };
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
                connected: !!Server().privateApi?.helper,
                port: PrivateApiService.port
            };
        });

        ipcMain.handle("reinstall-helper-bundle", async (_, __) => {
            return await Server().privateApi.modeType.install(true);
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

        ipcMain.handle("request-contact-permission", async (event, force) => {
            return await requestContactPermission(force);
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
            const count = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "image", after: args?.after });
            return count;
        });

        ipcMain.handle("get-chat-video-count", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getMediaCountsByChat({ mediaType: "video", after: args?.after });
            return count;
        });

        ipcMain.handle("get-group-message-counts", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getChatMessageCounts("group", args?.after);
            return count;
        });

        ipcMain.handle("get-individual-message-counts", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getChatMessageCounts("individual", args?.after);
            return count;
        });

        ipcMain.handle("get-best-friend", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const counts = await Server().iMessageRepo.getChatMessageCounts("individual", args?.after);

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

        ipcMain.handle("check-permissions", async (_, __) => {
            return await Server().checkPermissions();
        });

        ipcMain.handle("get-current-permissions", async (_, __) => {
            return {
                accessibility: systemPreferences.isTrustedAccessibilityClient(false),
                full_disk_access: Server().hasDiskAccess
            };
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
                log.info("No events to purge from event cache!");
            } else {
                log.info(`Purging ${Server().eventCache.size()} items from the event cache!`);
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

        ipcMain.handle("get-firebase-oauth-url", async (_, __) => {
            return await Server().oauthService?.getFirebaseOauthUrl();
        });

        ipcMain.handle("get-contacts-oauth-url", async (_, __) => {
            return await Server().oauthService?.getContactsOauthUrl();
        });

        ipcMain.handle("restart-oauth-service", async (_, __) => {
            if (Server().oauthService?.running) return;
            await Server().oauthService?.restart();
        });

        ipcMain.handle("save-lan-url", async (_, __) => {
            const useCustomCertificate = Server().repo.getConfig("use_custom_certificate") as boolean;
            const port = Server().repo.getConfig("socket_port") as number;
            const ips = FileSystem.getLocalIps("IPv4");
            const host = ips.length > 0 ? ips[0] : "localhost";
            const addr = `${useCustomCertificate ? "https" : "http"}://${host}:${port}`;
            await Server().repo.setConfig("server_address", addr);
        });

        ipcMain.handle("register-zrok-email", async (_, email) => {
            return await ZrokManager.getInvite(email);
        });

        ipcMain.handle("set-zrok-token", async (_, token) => {
            return await ZrokManager.setToken(token);
        });

        ipcMain.handle("disable-zrok", async (_, __) => {
            return await ZrokManager.disable();
        });

        ipcMain.handle("install-update", async (_, __) => {
            if (!Server().updater.hasUpdate) {
                return Server().log("No update available to install!", "debug");
            }

            shell.openExternal(Server().updater.updateInfo.html_url, { activate: true });
        });
    }
}
