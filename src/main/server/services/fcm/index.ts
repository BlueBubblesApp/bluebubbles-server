import * as admin from "firebase-admin";
import { Server } from "@server/index";
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
        } catch (ex) {
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
        if (!serverConfig || !clientConfig) return false;

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
        if (Server().ngrok?.isConnected()) await this.setServerUrl(Server().ngrok.url);

        return true;
    }

    /**
     * Sets the ngrok server URL within firebase
     *
     * @param serverUrl The new server URL
     */
    async setServerUrl(serverUrl: string): Promise<void> {
        if (!(await this.start())) return;

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
                } catch (ex) {
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
    ): Promise<admin.messaging.MessagingDevicesResponse[]> {
        if (!(await this.start())) return null;

        // Build out the notification message
        const msg: admin.messaging.DataMessagePayload = { data };
        const options: admin.messaging.MessagingOptions = { priority };

        const responses: admin.messaging.MessagingDevicesResponse[] = [];
        for (const device of devices)
            responses.push(await FCMService.getApp().messaging().sendToDevice(device, msg, options));

        return responses;
    }

    static async stop() {
        const app = FCMService.getApp();
        if (app) await app.delete();
    }
}
