import * as admin from "firebase-admin";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { RulesFile } from "firebase-admin/lib/security-rules/security-rules";
import { App } from "firebase-admin/app";
import axios from "axios";
import { isEmpty, resultRetryer, waitMs } from "@server/helpers/utils";

const AppName = "BlueBubbles";

enum DbType {
    UNKNOWN = "unknown",
    FIRESTORE = "firestore",
    REALTIME = "realtime"
}

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

    lastProjectId: string = null;

    lastProjectNumber: string = null;

    dbType = DbType.UNKNOWN;

    hasInitialized = false;

    startPromise: Promise<boolean> = null;

    serverConfig: any = null;

    clientConfig: any = null;

    addressUpdateLoop: NodeJS.Timeout = null;

    /**
     * Starts the FCM app service. Implements a retryer to ensure
     * that the service is started correctly.
     */
    async start({
        initializeOnly = false
    }: {
        initializeOnly?: boolean;
    } = {}): Promise<boolean> {
        // If the startup sequence is already occuring, wait for it to finish
        if (this.startPromise != null) {
            return await this.startPromise;
        }

        // Try starting the service
        let hasSucceeded = false;
        this.startPromise = resultRetryer({
            maxTries: 6,
            delayMs: 5000,
            getData: async () => {
                try {
                    const success = await this.startHandler({ initializeOnly });
                    hasSucceeded = true;
                    return success;
                } catch (ex: any) {
                    Server().log(`Failed to initialize FCM App. Error: ${ex?.message}. Retrying...`, "debug");
                    return null;
                }
            },
            // Retry if the data is null (an error happened)
            dataLoopCondition: (data: boolean) => data === null
        });

        const result = await this.startPromise;
        if (!hasSucceeded) {
            Server().log("Failed to initialize FCM App after 6 attempts!", "error");
        } else {
            this.initAddressUpdateLoop();
        }

        this.startPromise = null;
        return result;
    }

    private async initAddressUpdateLoop() {
        if (this.addressUpdateLoop) {
            clearInterval(this.addressUpdateLoop);
        }

        // Every 10 minutes, update the server address if it hasn't changed
        this.addressUpdateLoop = setInterval(() => {
            // If the app has been deleted (service stopped), clear the interval
            if (!FCMService.getApp()) {
                return clearInterval(this.addressUpdateLoop);
            }
    
            Server().log(`Attempting to update server URL (every 10 minute loop)...`, "debug");
            this.setServerUrl(true);
        }, 600000);
    }


    private async startHandler({
        initializeOnly = false
    }: {
        initializeOnly?: boolean;
    } = {}): Promise<boolean> {
        // If we have already initialized the app, don't re-initialize
        const app = FCMService.getApp();
        if (app) return true;

        Server().log("Initializing new FCM App");
        this.hasInitialized = false;

        // Load in the last restart date
        const lastRestart = Server().repo.getConfig("last_fcm_restart");
        this.lastRestart = !lastRestart ? 0 : (lastRestart as number);

        const hasConfigs = this.loadConfigs();
        if (!hasConfigs) {
            Server().log("FCM is not fully configured. Skipping...");
            return false;
        }

        this.dbType = (this.clientConfig.project_info?.firebase_url) ? DbType.REALTIME : DbType.FIRESTORE;

        // Initialize the app
        admin.initializeApp(
            {
                credential: admin.credential.cert(this.serverConfig),
                databaseURL: this.clientConfig.project_info.firebase_url,
                projectId: this.serverConfig.project_id
            },
            AppName
        );

        try {
            // Validate the project exists
            await this.validateProject(this.serverConfig.project_id);
        } catch (ex) {
            // Catch an error and stop the service
            await FCMService.stop();
            throw ex;
        }

        this.hasInitialized = true;

        if (!initializeOnly) {
            if (this.dbType === DbType.REALTIME) {
                await this.setRealtimeRules();
            }

            this.setServerUrl();
            this.listen();
        }
    
        return true;
    }

    loadConfigs(): boolean {
        this.serverConfig = FileSystem.getFCMServer();
        this.clientConfig = FileSystem.getFCMClient();
        return this.hasConfigs();
    }

    hasConfigs(): boolean {
        return !!this.serverConfig && !!this.clientConfig;
    }

    static async setFirestoreRulesForApp(app: App): Promise<void> {
        const source: RulesFile = {
            name: "firestore.rules",
            content: (
                "rules_version = '2';\n" +
                "service cloud.firestore {\n" +
                "  match /databases/{database}/documents {\n" +
                "    match /server/config {\n" +
                "      allow read;\n" +
                "    }\n" +
                "\n" +
                "    match /server/commands {\n" +
                "      allow write;\n" +
                "    }\n" +
                "  }\n" +
                "}"
            )
        };

        const rules = admin.securityRules(app);
        let shouldRefresh = true;
        
        try {
            // Get the current ruleset and only set the rules if they are different
            const currentRuleset = await rules.getFirestoreRuleset();
            const firestoreRules = currentRuleset?.source?.find((rule) => rule.name === source.name);
            if (firestoreRules?.content === source.content) shouldRefresh = false;
        } catch (ex: any) {
            // Do nothing
        }

        if (!shouldRefresh) return;
        const ruleset = await rules.createRuleset(source);
        await rules.releaseFirestoreRuleset(ruleset.name);
    }

    async setRealtimeRules() {
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

        const db = FCMService.getApp().database();

        // Set read rules
        await db.setRules(source);
    }

    clearLastValues() {
        this.lastRestart = 0;
        this.lastProjectId = null;
        this.lastProjectNumber = null;
    }

    /**
     * Checks to see if the URL has changed since the last time we updated it
     * 
     * @returns The new URL if it has changed, null otherwise
     */
    shouldUpdateUrl(): boolean{
        // Make sure we have configs in the first place
        if (!this.hasConfigs()) return null;

        // Make sure that information has changed
        return (
            this.lastProjectId !== this.serverConfig.project_id ||
            this.lastProjectNumber !== this.clientConfig?.project_info?.project_number
        );
    }

    /**
     * Sets the ngrok server URL within firebase
     *
     * @param serverUrl The new server URL
     */
    async setServerUrl(force = false): Promise<void> {
        // Make sure we should be setting the URL
        const shouldUpdate = this.shouldUpdateUrl();
        if (!shouldUpdate && !force) return;

        // Make sure we have a server address
        const serverUrl = Server().repo.getConfig("server_address") as string;
        if (isEmpty(serverUrl)) return;

        // Make sure that if we haven't initialized, we do so
        if (!this.hasInitialized || !(await this.start())) return;

        Server().log(`Updating Server Address in ${this.dbType} database...`);

        // Update the URL
        // If we fail, retry 12 times (for 1 minute)
        let error: any = null;
        const result = await resultRetryer({
            maxTries: 12,
            delayMs: 5000,
            getData: async () => {
                try {
                    Server().log(`Attempting to write server URL to database...`, 'debug');
                    await this.saveUrlToDb(serverUrl);
                    error = null;
                    return true;
                } catch (ex: any) {
                    error = ex;
                    return false;
                }
            }
        });

        if (!result) {
            Server().log(`Failed to update Server Address in ${this.dbType} Database after 3 attempts!`, "error");
            if (error) Server().log(`DB Update Error: ${error?.message}`, "debug");
        } else {
            Server().log('Successfully updated server address');
        }

        this.lastProjectId = this.serverConfig?.project_id;
        this.lastProjectNumber = this.clientConfig?.project_info?.project_number;
    }

    private async saveUrlToDb(serverUrl: string) {
        if (this.dbType === DbType.FIRESTORE) {
            await this.setServerUrlFirestore(serverUrl);
        } else if (this.dbType === DbType.REALTIME) {
            await this.setServerUrlRealtime(serverUrl);
        }
    }

    /**
     * Set the server URL in the Firestore.
     * If the current value is already the latest URL,
     * do not update it.
     *
     * @param serverUrl The new server URL
     */
    async setServerUrlFirestore(serverUrl: string): Promise<void> {
        const db = FCMService.getApp().firestore();
        const currentValue = (await db.collection("server").doc('config').get())?.data()?.serverUrl;
        if (currentValue !== serverUrl) {
            await db.collection("server").doc('config').set({ serverUrl });
        }
    }

     /**
     * Set the server URL in the Realtime DB.
     * If the current value is already the latest URL,
     * do not update it.
     *
     * @param serverUrl The new server URL
     */
    async setServerUrlRealtime(serverUrl: string): Promise<void> {
        const db = FCMService.getApp().database();

        // Update the config
        const config = db.ref("config");
        config.once("value", data => {
            const currentValue = data.val();
            if (currentValue !== serverUrl) {
                config.update({ serverUrl });
            }
        });
    }

    async validateProject(projectId: string): Promise<void> {
        const app = FCMService.getApp();
        const auth = await app.options.credential.getAccessToken();
        const headers: Record<string, string> = {
            Authorization: `Bearer ${auth.access_token}`,
            Accept: 'application/json'
        };

        try {
            await axios.request({
                method: 'GET',
                url: `https://firebase.googleapis.com/v1beta1/projects/${projectId}`,
                headers
            });
        } catch (ex: any) {
            const errorResponse = ex?.response.data;
            if (errorResponse?.error?.message) {
                // If the project has been deleted, we should unload the FCM configs.
                // And stop the service.
                if (errorResponse.error.message.includes('has been deleted')) {
                    Server().log(`Firebase Project ${projectId} has been deleted. Unloading FCM configs...`);
                    FileSystem.saveFCMClient(null);
                    FileSystem.saveFCMServer(null);
                }

                throw new Error(`Firebase Project Error: ${errorResponse.error.message}`);
            } else {
                throw new Error(`Firebase Project Error: ${ex?.message ?? String(ex)}`);
            }
        }
    }

    listen() {
        const app = FCMService.getApp();
        if (!app) return;

        Server().log('Listening for changes in Firebase...');
        if (this.dbType === DbType.FIRESTORE) {
            this.listenFirestoreDb();
        } else if (this.dbType === DbType.REALTIME) {
            this.listenRealtimeDb();
        }
    }

    private async listenFirestoreDb() {
        const app = FCMService.getApp();
        const db = app.firestore();
        
        const startListening = () => new Promise<void>((resolve, reject) => {
            db.collection("server")
                .doc("config")
                .onSnapshot(
                    (snapshot: admin.firestore.DocumentSnapshot) => {
                        this.nextRestartHandler(snapshot.data()?.nextRestart);
                        resolve();
                    }, async (error: any) => {
                        reject(error);
                    }
                );
        });
    
        // Try for 12 times (1 minute)
        let success = false;
        for (let i = 0; i < 12; i++) {
            try {
                await startListening();
                success = true;
                break;
            } catch (ex: any) {
                Server().log(`An error occurred when listening for DB changes! Retrying in 5 seconds...`, "debug");
                Server().log(ex?.message ?? String(ex));
                await waitMs(5000);
            }
        }

        if (!success) {
            Server().log(`Failed to listen for DB changes after 12 attempts!`, "error");
        } else {
            Server().log('Successfully listening for DB changes');
        }
    }

    private async listenRealtimeDb() {
        const app = FCMService.getApp();
        const db = app.database();

        const startListening = () => new Promise<void>((resolve, reject) => {
            db.ref("config")
                .child("nextRestart")
                .on(
                    "value",
                    async (snapshot: admin.database.DataSnapshot) => {
                        this.nextRestartHandler(snapshot.val());
                        resolve();
                    }, (error: any) => {
                        reject(error);
                    }
                );
        });

        // Try for 12 times (1 minute)
        let success = false;
        for (let i = 0; i < 12; i++) {
            try {
                await startListening();
                success = true;
                break;
            } catch (ex: any) {
                Server().log(`An error occurred when listening for DB changes! Retrying in 5 seconds...`, "debug");
                Server().log(ex?.message ?? String(ex));
                await waitMs(5000);
            }
        }

        if (!success) {
            Server().log(`Failed to listen for DB changes after 12 attempts!`, "error");
        } else {
            Server().log('Successfully listening for DB changes');
        }
    }

    private async nextRestartHandler(value: any) {
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
            if (!this.hasInitialized || !(await this.start())) return null;

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
            const response = await FCMService.getApp().messaging().sendEachForMulticast(payload);
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
