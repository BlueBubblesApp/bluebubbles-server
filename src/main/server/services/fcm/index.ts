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

    /**
     * Starts the FCM app service
     */
    async start(refresh = false): Promise<boolean> {
        // If we have already initialized the app, don't re-initialize
        const app = FCMService.getApp();
        if (app && !refresh) return true;

        // Do nothing if the config doesn't exist
        const serverConfig = FileSystem.getFCMServer();
        const clientConfig = FileSystem.getFCMClient();
        if (!serverConfig || !clientConfig) return false;

        // If we want to do a full refresh, delete the current app
        try {
            if (app && refresh) await app.delete();
        } catch (ex) {
            /* Ignore */
        }

        // Initialize the app
        admin.initializeApp(
            {
                credential: admin.credential.cert(serverConfig),
                databaseURL: clientConfig.project_info.firebase_url
            },
            AppName
        );

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
                    ".write": false
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

    /**
     * Sends a notification to all connected devices
     *
     * @param devices Devices to send the notification to
     * @param data The data to send
     */
    async sendNotification(devices: string[], data: any): Promise<admin.messaging.MessagingDevicesResponse[]> {
        if (!(await this.start())) return null;

        // Build out the notification message
        const msg: admin.messaging.DataMessagePayload = { data };
        const options: admin.messaging.MessagingOptions = { priority: "high" };

        const responses: admin.messaging.MessagingDevicesResponse[] = [];
        for (const device of devices)
            responses.push(await FCMService.getApp().messaging().sendToDevice(device, msg, options));

        return responses;
    }
}
