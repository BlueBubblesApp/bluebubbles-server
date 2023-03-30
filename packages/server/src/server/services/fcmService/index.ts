import * as admin from "firebase-admin";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";

const AppName = "BlueBubbles";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FCMService {
    static getApp(): admin.app.App {
        try {
            return admin.app(AppName);
        } catch (ex: any) {
            return null;
        }
    }

    lastRestart = 0;

    /**
     * Starts the FCM app service
     */
    async start(): Promise<boolean> {
        // If we have already initialized the app, don't re-initialize
        const app = FCMService.getApp();
        if (app) return true;

        Server().log("Initializing new FCM App");

        // Load in the last restart date
        const lastRestart = Server().repo.getConfig("last_fcm_restart");
        this.lastRestart = !lastRestart ? 0 : (lastRestart as number);

        // Do nothing if the config doesn't exist
        const serverConfig = FileSystem.getFCMServer();
        const clientConfig = FileSystem.getFCMClient();
        if (!serverConfig || !clientConfig) {
            Server().log("FCM is not fully configured. Skipping...");
            return false;
        }

        // Initialize the app
        admin.initializeApp(
            {
                credential: admin.credential.cert(serverConfig),
                databaseURL: clientConfig.project_info.firebase_url
            },
            AppName
        );

        this.listen();

        // Set the current ngrok URL if we are connected
        for (const service of Server().proxyServices) {
            if (service.isConnected()) {
                await this.setServerUrl(service.url);
                break;
            }
        }

        return true;
    }

    /**
     * Sets the ngrok server URL within firebase
     *
     * @param serverUrl The new server URL
     */
    async setServerUrl(serverUrl: string): Promise<void> {
        if (!(await this.start())) return;
        if (!serverUrl) return;

        Server().log("Updating Server Address in Firebase Database...");

        // Set the rules
        const source = JSON.stringify(
            {
                rules: {
                    ".read": true,
                    ".write": false,
                    config: {
                        nextRestart: {
                            ".write": true
                        }
                    }
                }
            },
            null,
            4
        );

        const db = admin.app(AppName).database();

        // Set read rules
        await db.setRules(source);

        // Update the config
        const config = db.ref("config");
        config.once("value", _ => {
            config.update({ serverUrl });
        });
    }

    async listen() {
        const app = FCMService.getApp();
        if (!app) return;

        const db = app.database();
        db.ref("config")
            .child("nextRestart")
            .on("value", async (snapshot: admin.database.DataSnapshot) => {
                const value = snapshot.val();
                if (!value) return;

                try {
                    if (value > this.lastRestart) {
                        Server().log("Received request to restart via FCM! Restarting...");

                        // Update the last restart values
                        await Server().repo.setConfig("last_fcm_restart", value);
                        this.lastRestart = value;

                        // Do a restart
                        await Server().relaunch();
                    }
                } catch (ex: any) {
                    Server().log(`Failed to restart after FCM request!\n${ex}`, "error");
                }
            });
    }

    /**
     * Sends a notification to all connected devices
     *
     * @param devices Devices to send the notification to
     * @param data The data to send
     */
    async sendNotification(
        devices: string[],
        data: any,
        priority: "normal" | "high" = "normal"
    ): Promise<admin.messaging.BatchResponse> {
        try {
            if (!(await this.start())) return null;

            // Build out the notification message
            const payload: admin.messaging.MulticastMessage = {
                data,
                tokens: devices,
                android: {
                    priority,
                    ttl: 60 * 60 * 24 // 24 hr expiration
                }
            };

            Server().log(`Sending FCM notification (Priority: ${priority}) to ${devices.length} device(s)`, "debug");
            const response = await FCMService.getApp().messaging().sendMulticast(payload);
            if (response.failureCount > 0) {
                response.responses.forEach(resp => {
                    if (!resp.success && resp.error) {
                        const code = resp.error?.code;
                        const msg = resp.error?.message;
                        if (code === "messaging/payload-size-limit-exceeded") {
                            // Manually handle the size limit error
                            Server().log(
                                "Could not send Firebase Notification due to payload exceeding size limits!",
                                "warn"
                            );
                            Server().log(`Failed notification Payload: ${JSON.stringify(data)}`, "debug");
                        } else if (code !== "messaging/registration-token-not-registered") {
                            // Ignore token not registered errors
                            Server().log(`Firebase returned the following error (Code: ${code}): ${msg}`, "error");

                            if (resp.error?.stack) {
                                Server().log(`Firebase Stacktrace: ${resp.error.stack}`, "debug");
                            }
                        }
                    }
                });
            }

            return response;
        } catch (ex: any) {
            Server().log(`Failed to send notification! ${ex.message}`);
        }

        return { responses: [], successCount: 0, failureCount: 0 };
    }

    async restart() {
        await FCMService.stop();
        await this.start();
    }

    static async stop() {
        const app = FCMService.getApp();
        if (app) await app.delete();
    }
}
