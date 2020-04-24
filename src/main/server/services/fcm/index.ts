import * as admin from "firebase-admin";
import { FileSystem } from "@server/fileSystem";

export class FCMService {
    fs: FileSystem;

    app: admin.app.App;

    constructor(fs: FileSystem) {
        this.fs = fs;
        this.app = null;
    }

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

    async sendNotification(devices: string[], data: any) {
        const msg = { data, tokens: devices };
        const res = await this.app.messaging().sendMulticast(msg);
        return res;
    }
}