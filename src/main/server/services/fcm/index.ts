import * as admin from "firebase-admin";
import { FileSystem } from "@server/fileSystem";

/**
 * This services manages the connection to the connected
 * Google FCM server. This is used to handle/manage notifications
 */
export class FCMService {
    fs: FileSystem;

    app: admin.app.App;

    constructor(fs: FileSystem) {
        this.fs = fs;
        this.app = null;
    }

    /**
     * Starts the FCM connection, depending if a user has it configured.
     * Does not set it up if the required files are not present
     */
    start() {
        // Do nothing if the config doesn't exist
        const serverConfig = this.fs.getFCMServer();
        const clientConfig = this.fs.getFCMClient();
        if (!serverConfig || !clientConfig) return;
        
        // If the app exists, close it
        if (this.app) this.app.delete();

        // Re-instantiate the app
        this.app = admin.initializeApp({
            credential: admin.credential.cert(serverConfig),
            databaseURL: clientConfig.project_info.firebase_url
        });
    }

    /**
     * Sends a notification to all connected devices
     *
     * @param devices Devices to send the notification to
     * @param data The data to send
     */
    async sendNotification(devices: string[], data: any) {
        // Build out the notification message
        const msg: admin.messaging.MulticastMessage = { data, tokens: devices };
        const res = await this.app.messaging().sendMulticast(msg);
        return res;
    }
}