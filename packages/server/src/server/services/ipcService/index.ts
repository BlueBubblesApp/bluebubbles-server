import { app, dialog, ipcMain, nativeTheme, systemPreferences } from "electron";

import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { AlertService } from "@server/services/alertService";
import { openLogs } from "@server/api/v1/apple/scripts";
import { fixServerUrl, onlyAlphaNumeric } from "@server/helpers/utils";
import { ContactInterface } from "@server/api/v1/interfaces/contactInterface";
import { BlueBubblesHelperService } from "../privateApi";

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
            const alerts = await AlertService.find();
            return alerts;
        });

        ipcMain.handle("mark-alerts-as-read", async (_, args) => {
            for (const i of args) {
                await AlertService.markAsRead(i);
                Server().notificationCount -= 1;
            }

            if (Server().notificationCount < 0) Server().notificationCount = 0;
            app.setBadgeCount(Server().notificationCount);
        });

        ipcMain.handle("set-fcm-server", async (_, args) => {
            FileSystem.saveFCMServer(args);
        });

        ipcMain.handle("set-fcm-client", async (_, args) => {
            FileSystem.saveFCMClient(args);
            await Server().fcm.start();
        });

        ipcMain.handle("get-devices", async (event, args) => {
            return await Server().repo.devices().find();
        });

        ipcMain.handle("get-private-api-requirements", async (_, __) => {
            return await Server().checkPrivateApiRequirements();
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

        ipcMain.handle("get-contacts", async (event, _) => {
            return await ContactInterface.getAllContacts();
        });

        ipcMain.handle("add-contact", async (event, args) => {
            return await ContactInterface.createContact({
                firstName: args.firstName,
                lastName: args.lastName,
                emails: args.emails ?? [],
                phoneNumbers: args.phoneNumbers ?? []
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

        ipcMain.handle("get-contact-name", async (event, address) => {
            const res = await ContactInterface.queryContacts([address]);
            return res && res.length > 0 ? res[0] : null;
        });

        ipcMain.handle("toggle-tutorial", async (_, toggle) => {
            await Server().repo.setConfig("tutorial_is_done", toggle);

            if (toggle) {
                await Server().hotRestart();
            }
        });

        ipcMain.handle("get-message-count", async (event, args) => {
            if (!Server().iMessageRepo?.db) return 0;
            const count = await Server().iMessageRepo.getMessageCount(args?.after, args?.before, args?.isFromMe);
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

        ipcMain.handle("hot-restart", async (_, __) => {
            await Server().hotRestart();
        });

        ipcMain.handle("full-restart", async (_, __) => {
            await Server().relaunch();
        });

        ipcMain.handle("show-dialog", (_, opts: Electron.MessageBoxOptions) => {
            return dialog.showMessageBox(Server().window, opts);
        });

        ipcMain.handle("open-log-location", (_, __) => {
            FileSystem.executeAppleScript(openLogs());
        });

        ipcMain.handle("clear-alerts", async (_, __) => {
            Server().notificationCount = 0;
            app.setBadgeCount(0);
            await Server().repo.alerts().clear();
        });
    }
}
