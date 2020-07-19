import * as admin from "firebase-admin";
import { Server } from "@server/index";
import { FileSystem } from "@server/fileSystem";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FCMService {
    app: admin.app.App;

    lastRefresh: Date;

    constructor() {
        this.app = null;
        this.lastRefresh = null;
    }

    /**
     * Starts the FCM connection, depending if a user has it configured.
     * Does not set it up if the required files are not present
     */
    start() {
        // Force refresh a new connection
        this.refresh(true);
    }

    private async refresh(force = false): Promise<boolean> {
        // Do nothing if the config doesn't exist
        const serverConfig = FileSystem.getFCMServer();
        const clientConfig = FileSystem.getFCMClient();
        if (!serverConfig || !clientConfig) return false;

        const now = new Date();

        // Refresh JWT every 60 minutes
        if (force || !this.lastRefresh || now.getTime() - this.lastRefresh.getTime() > 3600000) {
            // Re-instantiate the app
            this.lastRefresh = new Date();
            if (this.app) this.app.delete(); // Kill the old connection

            // Create the new connection
            this.app = admin.initializeApp({
                credential: admin.credential.cert(serverConfig),
                databaseURL: clientConfig.project_info.firebase_url
            });

            // Set the current ngrok URL if we are connected
            if (Server().ngrok?.isConnected()) await this.setServerUrl(Server().ngrok.url);
        }

        return true;
    }

    /**
     * Sets the ngrok server URL within firebase
     *
     * @param serverUrl The new server URL
     */
    async setServerUrl(serverUrl: string): Promise<void> {
        if (!(await this.refresh())) return;

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
        await admin.database().setRules(source);

        // Add the config value
        const db = admin.database();
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
        if (!(await this.refresh())) return null;

        // Build out the notification message
        const msg: admin.messaging.DataMessagePayload = { data };
        const options: admin.messaging.MessagingOptions = { priority: "high" };

        const responses: admin.messaging.MessagingDevicesResponse[] = [];
        for (const device of devices) responses.push(await this.app.messaging().sendToDevice(device, msg, options));

        return responses;
    }
}
