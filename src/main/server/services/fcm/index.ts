import * as admin from "firebase-admin";
import { FileSystem } from "@server/fileSystem";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FCMService {
    fs: FileSystem;

    app: admin.app.App;

    lastRefresh: Date;

    constructor(fs: FileSystem) {
        this.fs = fs;
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

    private refresh(force = false): boolean {
        // Do nothing if the config doesn't exist
        const serverConfig = this.fs.getFCMServer();
        const clientConfig = this.fs.getFCMClient();
        if (!serverConfig || !clientConfig) return;

        const now = new Date();

        // Refresh JWT every 60 minutes
        if (force || !this.lastRefresh || now.getTime() - this.lastRefresh.getTime() > 3600000) {
            // Re-instantiate the app
            this.lastRefresh = new Date();
            if (this.app) this.app.delete(); // Kill the old connection
            this.app = admin.initializeApp({
                credential: admin.credential.cert(serverConfig),
                databaseURL: clientConfig.project_info.firebase_url
            });
        }

        return true;
    }

    /**
     * Sets the ngrok server URL within firebase
     *
     * @param serverUrl The new server URL
     */
    setServerUrl(serverUrl: string): void {
        if (!this.refresh()) return;

        const db = admin.database();
        const config = db.ref("config");

        config.once("value", (data) => {
            config.update({ serverUrl });
        });
    }

    /**
     * Sends a notification to all connected devices
     *
     * @param devices Devices to send the notification to
     * @param data The data to send
     */
    async sendNotification(devices: string[], data: any): Promise<admin.messaging.BatchResponse> {
        if (!this.refresh()) return null;

        // Build out the notification message
        const msg: admin.messaging.MulticastMessage = { data, tokens: devices };
        const res = await this.app.messaging().sendMulticast(msg);
        return res;
    }
}
