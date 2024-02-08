// HTTP libraries
import KoaApp from "koa";
import http from "http";
import axios from "axios";

// Internal libraries
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import * as admin from "firebase-admin";
import { OAuth2Client } from "google-auth-library";
import { Auth, google } from "googleapis";
import { generateRandomString } from "@server/utils/CryptoUtils";
import { getObjectAsString, isEmpty, isNotEmpty, waitMs } from "@server/helpers/utils";
import { ProgressStatus } from "@server/types";
import { FCMService } from "../fcmService";
import { BrowserWindow, HandlerDetails } from "electron";

/**
 * This service class hhandles the initial oauth workflows
 */
export class OauthService {
    running = false;

    koaApp: KoaApp;

    httpServer: http.Server;

    httpOpts: any;

    oauthClient: OAuth2Client;

    port = 8641;

    authToken: string;

    expiresIn: number;

    projectName = "BlueBubbles";

    private clientId = "500464701389-os4g4b8mfoj86vujg4i61dmh9827qbrv.apps.googleusercontent.com";

    private _packageName = "com.bluebubbles.messaging";

    completed = false;

    private scopes = [
        "https://www.googleapis.com/auth/cloudplatformprojects",
        "https://www.googleapis.com/auth/service.management",
        "https://www.googleapis.com/auth/firebase",
        "https://www.googleapis.com/auth/datastore",
        "https://www.googleapis.com/auth/iam"
    ];

    get callbackUrl(): string {
        return `http://localhost:${this.port}/oauth/callback`;
    }

    constructor() {
        this.oauthClient = new google.auth.OAuth2(this.clientId, null, this.callbackUrl);
    }

    set packageName(name: string) {
        this._packageName = name.toLowerCase().replaceAll("-", "_");
    }

    get packageName() {
        return this._packageName;
    }

    initialize() {
        // Create the HTTP server
        this.koaApp = new KoaApp();
        this.configureKoa();
        this.httpServer = http.createServer(this.koaApp.callback());
    }

    configureKoa() {
        if (!this.koaApp) return;

        // Create a route to intercept the oauth callback
        this.koaApp.use(async (ctx, _) => {
            if (ctx.path === "/oauth/callback") {
                Server().log("Received oauth callback");
                ctx.body = "Success! You can close this window and return to the BlueBubbles Server app";
                ctx.status = 200;
            } else {
                ctx.body = "Not found";
                ctx.status = 404;
            }
        });
    }

    /**
     * Handles the project creation workflow.
     * When the flow is complete, the JSON files will be saved to the resources folder.
     * The service will then stop itself upon successful completion.
     */
    async handleProjectCreation() {
        try {
            Server().emitToUI("oauth-status", ProgressStatus.IN_PROGRESS);

            Server().log(`[GCP] Creating Google Cloud project, "${this.projectName}"...`);
            const project = await this.createGoogleCloudProject();
            const projectId = project.projectId;

            // Enable the required APIs
            await this.enableCloudApis(projectId);
            await this.enableCloudResourceManager(projectId);
            await this.enableFirebaseManagementApi(projectId);
            await this.enableFirestoreApi(projectId);

            Server().log(`[GCP] Adding Firebase to Google Cloud Project`);
            await this.addFirebase(projectId);

            Server().log(`[GCP] Waiting for Service Account to generate (this may take some time)...`);
            const serviceAccountJson = await this.getServiceAccount(projectId);

            Server().log(`[GCP] Creating Firestore...`);
            await this.createDatabase(projectId);

            Server().log(`[GCP] Creating Android Configuration...`);
            await this.createAndroidApp(projectId);

            Server().log(`[GCP] Generating Google Services JSON (this may take some time)...`);
            const servicesJson = await this.getGoogleServicesJson(projectId);

            // Check if the current firebase server config is different from the previous.
            // If it is, we should log a warning and clear the devices.
            const serverFcm = FileSystem.getFCMServer();
            if (serverFcm?.project_id != null && serviceAccountJson?.project_id !== serverFcm?.project_id) {
                Server().log(
                    "Detected change in Firebase project! Clearing devices to prevent notification conflicts. " +
                        "You may need to re-register your devices to receive notifications.",
                    "warn"
                );

                await Server().repo.devices().clear();
            }

            // Save the configurations
            FileSystem.saveFCMServer(serviceAccountJson);
            FileSystem.saveFCMClient(servicesJson);

            // Set the security rules for the project.
            Server().log(`[GCP] Creating Firestore Security Rules...`);
            await this.createSecurityRules(projectId);

            Server().log(`[GCP] Revoking OAuth token, to prevent further use...`);
            try {
                await this.oauthClient.revokeToken(this.authToken);
            } catch {
                // Do nothing
            }

            // Wait 10 seconds to ensure credentials propogate
            Server().log(`[GCP] Ensuring credentials are propogated..`);
            await waitMs(10000);

            // Mark the service as completed
            Server().log(
                `[GCP] Successfully created and configured your Google Project! ` + `You may now continue with setup.`
            );
            this.completed = true;
            Server().emitToUI("oauth-status", ProgressStatus.COMPLETED);

            // Shutdown the service
            await this.stop();

            // Start the FCM service.
            // Don't await because we don't want to catch the error here.
            FCMService.stop()
                .then(async () => {
                    // Clear our markers & start the service
                    Server().fcm.clearLastValues();
                    await Server().fcm.start();
                })
                .catch(async err => {
                    Server().log("An issue occurred when stopping the FCM service after OAuth completion!", "debug");
                    Server().log(err?.message ?? String(err), "debug");
                });
        } catch (ex: any) {
            Server().log(`[GCP] Failed to create project: ${ex?.message}`, "error");
            if (ex?.response?.data?.error) {
                Server().log(`[GCP] (${ex.response.data.error.code}) ${ex.response.data.error.message}`, "debug");
            }
            // eslint-disable-next-line max-len
            Server().log(
                `[GCP] Use the Google Login button and try again. If the issue persists, please contact support.`,
                "debug"
            );
            Server().emitToUI("oauth-status", ProgressStatus.FAILED);
        }
    }

    /**
     * Generates the OAuth URL for the client/UI to use.
     *
     * @returns The OAuth URL
     */
    async getOauthUrl() {
        const url = await this.oauthClient.generateAuthUrl({
            scope: this.scopes,
            response_type: "token"
        });

        return url;
    }

    /**
     * Starts the HTTP server
     */
    start() {
        Server().log("Starting OAuth Service...");
        this.running = true;

        // Start the server
        this.httpServer.listen(this.port, () => {
            Server().log(`Successfully started OAuth2 server`);
        });
    }

    async checkIfProjectExists() {
        // eslint-disable-next-line max-len
        const getUrl = `https://cloudresourcemanager.googleapis.com/v1/projects?filter=name%3A${this.projectName}%20AND%20lifecycleState%3AACTIVE`;
        const getRes = await this.sendRequest("GET", getUrl);

        // Check if the project already exists and return the data if it does
        const projectMatch = (getRes.data?.projects ?? []).length > 0;
        if (projectMatch) {
            Server().log(`[GCP] Project "${this.projectName}" already exists!`);
            return getRes.data.projects[0];
        }

        return null;
    }

    /**
     * Creates the Google Cloud Project
     * If the project already exists & is active, it returns the existing one
     *
     * @returns The project object
     */
    async createGoogleCloudProject() {
        let projectId: string = null;

        // First check if the project exists
        const projectExists = await this.checkIfProjectExists();
        if (projectExists) return projectExists;

        // Helper function to create a new project
        const createProj = async () => {
            const postUrl = `https://cloudresourcemanager.googleapis.com/v1/projects`;
            projectId = `${this.projectName.toLowerCase()}-${generateRandomString(4)}`;
            const data = { name: this.projectName, projectId };
            Server().log(`[GCP] Creating project with name, "${this.projectName}", under project ID, "${projectId}"`);
            const createRes = await this.sendRequest("POST", postUrl, data);

            // Wait for the operation to complete (try for 2 minutes)
            const operationName = createRes.data.name;
            const operationUrl = `https://cloudresourcemanager.googleapis.com/v1/${operationName}`;
            return await this.waitForData("GET", operationUrl, null, "done", 60, 5000);
        };

        let operationData = await createProj();

        // If there is an error, throw it
        if (isNotEmpty(operationData?.error)) {
            const isTosError = operationData.error.message.includes("Terms of Service");
            if (isTosError) {
                Server().log(
                    `[GCP] You must accept the Google Cloud Terms of Service before continuing! ` +
                        `A window will open in 10 seconds for you to accept the TOS. ` +
                        `Once you accept the TOS, you can close the window and setup will continue.`
                );

                await waitMs(10000);
                await this.openWindow("https://console.cloud.google.com/projectcreate");
            } else {
                throw new Error(`Error: ${getObjectAsString(operationData.error)}`);
            }

            // Try again
            Server().log(`[GCP] Retrying project creation...`);
            operationData = await createProj();
        }

        // Throw an error if a project ID isn't returned
        if (isEmpty(operationData?.response?.projectId)) {
            throw new Error(`No Project ID was returned!`);
        }

        await waitMs(2000);

        // Fetch the project data
        // eslint-disable-next-line max-len
        const getUrl = `https://cloudresourcemanager.googleapis.com/v1/projects?filter=name%3A${this.projectName}%20AND%20lifecycleState%3AACTIVE`;
        const projectData = await this.sendRequest("GET", getUrl);
        return projectData.data.projects.find((p: any) => p.projectId === projectId);
    }

    async enableCloudApis(projectId: string) {
        Server().log(`[GCP] Enabling Cloud APIs`);
        await this.enableService(projectId, "cloudapis.googleapis.com");
    }

    async enableFirebaseManagementApi(projectId: string) {
        Server().log(`[GCP] Enabling Firebase Management APIs`);
        await this.enableService(projectId, "firebase.googleapis.com");
    }

    async enableFirestoreApi(projectId: string) {
        Server().log(`[GCP] Enabling Firestore APIs`);
        await this.enableService(projectId, "firestore.googleapis.com");
    }

    async enableCloudResourceManager(projectId: string) {
        Server().log(`[GCP] Enabling Cloud Resource Manager APIs`);
        await this.enableService(projectId, "cloudresourcemanager.googleapis.com");
    }

    async enableIdentityApi(projectId: string) {
        Server().log(`[GCP] Enabling IAM APIs`);
        await this.enableService(projectId, "iam.googleapis.com");
    }

    async enableService(projectId: string, service: string) {
        const postUrl = `https://serviceusage.googleapis.com/v1/projects/${projectId}/services/${service}:enable`;
        const createRes = await this.sendRequest("POST", postUrl, {});

        // If the operation is already done, return
        const operationName = createRes.data.name;
        if (operationName.endsWith("DONE_OPERATION")) return;

        // Wait for the operation to complete
        const operationUrl = `https://serviceusage.googleapis.com/v1/${operationName}`;
        return await this.waitForData("GET", operationUrl, null, "done", 30, 5000);
    }

    /**
     * Adds Firebase to the Google Cloud Project
     *
     * @param projectId The project ID
     * @throws An HTTP error if the error code is not 409
     */
    async addFirebase(projectId: string) {
        try {
            const url = `https://firebase.googleapis.com/v1beta1/projects/${projectId}:addFirebase`;
            const res = await this.sendRequest("POST", url, {});
            await this.waitForData("GET", `https://firebase.googleapis.com/v1beta1/${res.data.name}`, null, "name");
            await waitMs(5000); // Wait 5 seconds to ensure Firebase is ready
        } catch (ex: any) {
            if (ex.response?.data?.error?.code === 409) {
                Server().log(`[GCP] Firebase already exists!`);
            } else if (ex.response?.data?.error?.code === 403) {
                await this.addFirebaseManual();
            } else {
                Server().log(
                    `Failed to add Firebase to project: Data: ${getObjectAsString(ex.response?.data)}`,
                    "debug"
                );
                throw new Error(
                    `Failed to add Firebase to project: ${getObjectAsString(
                        ex.response?.data?.error?.message ?? ex.message
                    )}}`
                );
            }
        }
    }

    async addFirebaseManual() {
        Server().log(
            `[GCP] You must manually create the Firebase project! In 10 seconds, ` +
                `a window will open where you can create a new project. ` +
                `Select your existing BlueBubbles Resource and add Firebase to the project. ` +
                `Once the project is created, you can close the window and setup will continue.`
        );

        await waitMs(10000);
        await this.openWindow(`https://console.firebase.google.com/`);
        Server().log(`[GCP] Resuming setup...`);
    }

    /**
     * Creates the default database for the Google Cloud Project
     *
     * @param projectId The project ID
     * @throws An HTTP error if the error code is not 409
     */
    async createDatabase(projectId: string) {
        const dbName = "(default)";

        try {
            const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases?databaseId=${dbName}`;
            const data = { type: "FIRESTORE_NATIVE", locationId: "nam5" };
            await this.sendRequest("POST", url, data);

            // Wait for the DB to be created
            await this.waitForData(
                "GET",
                `https://firestore.googleapis.com/v1/projects/${projectId}/databases`,
                null,
                "databases"
            );
        } catch (ex: any) {
            if (ex.response?.data?.error?.code === 409) {
                Server().log(`[GCP] Firestore already exists!`);
            } else {
                throw ex;
            }
        }
    }

    /**
     * Creates an Android app configuration for the Google Cloud Project
     *
     * @param projectId The project ID
     * @throws An HTTP error if the error code is not 409
     */
    async createAndroidApp(projectId: string) {
        try {
            const url = `https://firebase.googleapis.com/v1beta1/projects/${projectId}/androidApps`;
            const data = { displayName: this.projectName, packageName: this.packageName };
            const createRes = await this.sendRequest("POST", url, data);

            // Wait for the app to be created
            const operationName = createRes.data.name;
            const operationUrl = `https://firebase.googleapis.com/v1beta1/${operationName}`;
            const operationResult = await this.waitForData("GET", operationUrl, null, "done", 60, 5000);
            if (operationResult.error) {
                throw new Error(`Failed to create Android App: ${getObjectAsString(operationResult.error)}`);
            }
        } catch (ex: any) {
            if (ex.response?.data?.error?.code === 409) {
                Server().log(`[GCP] Android Configuration already exists!`);
            } else {
                throw ex;
            }
        }
    }

    /**
     * Creates a Service Account for a given Google Cloud Project.
     *
     * @param projectId The project ID
     * @param serviceAccountName The name of the service account
     * @returns The service account data
     */
    async createServiceAccount(projectId: string, serviceAccountName: string) {
        const url = `https://iam.googleapis.com/v1/projects/${projectId}/serviceAccounts`;
        const data = {
            accountId: serviceAccountName,
            serviceAccount: {
                displayName: serviceAccountName,
                description: "Firebase Admin SDK Service Agent"
            }
        };
        const res = await this.sendRequest("POST", url, data);
        return res.data;
    }

    /**
     * Gets the Service Account ID from the Google Cloud Project
     *
     * @param projectId The project ID
     * @returns The service account ID
     */
    async getFirebaseServiceAccountId(projectId: string): Promise<string> {
        const url = `https://iam.googleapis.com/v1/projects/${projectId}/serviceAccounts`;

        try {
            // Max wait time: 5 minutes (60 attempts with 5 second delay)
            const response = await this.waitForData("GET", url, null, "accounts", 60, 5000);
            const firebaseServiceAccounts = response.accounts;
            const firebaseServiceAccountId = firebaseServiceAccounts.find(
                (element: any) => element.displayName === "firebase-adminsdk"
            )?.uniqueId;
            return firebaseServiceAccountId;
        } catch {
            return null;
        }
    }

    /**
     * Gets the Service Account private key from the Google Cloud Project
     *
     * @param projectId The project ID
     * @returns The service account private key JSON string
     */
    async getServiceAccount(projectId: string) {
        const accountId: string = await this.getFirebaseServiceAccountId(projectId);
        if (!accountId) {
            throw new Error("Failed to get Firebase Service Account! Please ensure that the project was created!");
        }

        // eslint-disable-next-line max-len
        const url = `https://iam.googleapis.com/v1/projects/${projectId}/serviceAccounts/${accountId}/keys`;

        // Get the existing keys, deleting all the user managed keys
        const getRes = await this.sendRequest("GET", url);
        const existingKeys = getRes.data.keys ?? [];
        const userManagedKeys = existingKeys.filter((key: any) => key.keyType === "USER_MANAGED");

        let removed = 0;
        for (const key of userManagedKeys) {
            const deleteUrl = `https://iam.googleapis.com/v1/${key.name}`;
            await this.sendRequest("DELETE", deleteUrl);
            removed += 1;
        }

        if (removed > 0) {
            Server().log(`[GCP] Removed ${removed} existing ServiceAccount key(s)`);
            await waitMs(5000); // Wait 5 seconds for the keys to be removed
            Server().log(`[GCP] Creating new Service Account key...`);
        }

        const response = await this.sendRequest("POST", url);
        const b64Key = response.data.privateKeyData;
        const privateKeyData = Buffer.from(b64Key, "base64").toString("utf-8");
        return JSON.parse(privateKeyData);
    }

    /**
     * Gets the Google Services JSON from the Google Cloud Project (Android Config)
     *
     * @param projectId The project ID
     * @returns The Google Services JSON string
     */
    async getGoogleServicesJson(projectId: string) {
        const url = `https://firebase.googleapis.com/v1beta1/projects/${projectId}/androidApps`;
        const appsRes = await this.sendRequest("GET", url);
        const appId = (appsRes.data.apps ?? []).find((app: any) => app.packageName === this.packageName).appId;
        if (!appId) throw new Error(`Could not find appId for package name ${this.packageName}`);

        // eslint-disable-next-line max-len
        const cfgUrl = `https://firebase.googleapis.com/v1beta1/projects/${projectId}/androidApps/${appId}/config`;
        const cfgRes = await this.sendRequest("GET", cfgUrl);
        const b64Config = cfgRes.data.configFileContents;
        const config = Buffer.from(b64Config, "base64").toString("utf-8");
        return JSON.parse(config);
    }

    /**
     * Waits for an endpoint to return data
     *
     * @param method The HTTP method
     * @param url The URL
     * @param data The data to send (optional)
     * @param key The key to check for in the response data (optional)
     */
    async waitForData(
        method: "GET" | "POST",
        url: string,
        data: Record<string, any> = null,
        key: string = null,
        maxAttempts = 30,
        waitTime = 2000
    ) {
        let attempts = 0;

        // eslint-disable-next-line no-constant-condition
        while (true) {
            const res = await this.sendRequest(method, url, data);
            if (!key && isNotEmpty(res.data)) return res.data;
            if (key && isNotEmpty(res.data[key])) return res.data;

            attempts += 1;
            if (attempts > maxAttempts) {
                Server().log(`Received data from failed request: ${getObjectAsString(res.data)}`, "debug");
                throw new Error(
                    `Failed to get data from: ${url}. Please gather server logs and contact the developers!`
                );
            }

            await waitMs(waitTime);
        }
    }

    /**
     * Waits for an endpoint to return data
     *
     * @param method The HTTP method
     * @param url The URL
     * @param data The data to send (optional)
     * @param key The key to check for in the response data (optional)
     */
    async tryUntilNoError(method: "GET" | "POST", url: string, data: Record<string, any> = null, maxAttempts = 30) {
        let attempts = 0;
        const waitTime = 2000;

        // eslint-disable-next-line no-constant-condition
        while (true) {
            try {
                const res = await this.sendRequest(method, url, data);
                return res.data;
            } catch (ex: any) {
                // For duplicates, just throw the error so it can be handled properly.
                if (ex.response?.data?.error?.code === 409) throw ex;
                attempts += 1;
                if (attempts > maxAttempts) throw ex;
                await waitMs(waitTime);
            }
        }
    }

    async createSecurityRules(projectId: string) {
        // Uninitialize the app if it exists
        const appName = "BlueBubbles-OAuth";
        const existingApp = admin.apps.find(app => app.name === appName);
        if (existingApp) await existingApp.delete();

        // Create a custom SDK app using the auth token we received from
        // the oauth consent flow. We do this here because when this is
        // done using service account credentials, a permission error occurs.
        const app = admin.initializeApp(
            {
                credential: {
                    getAccessToken: async () => {
                        return {
                            access_token: this.authToken,
                            expires_in: this.expiresIn
                        };
                    }
                },
                projectId
            },
            appName
        );

        await FCMService.setFirestoreRulesForApp(app);
        await app.delete();
    }

    /**
     * Sends a generic request to the Google Cloud API.
     * This will automatically apply the correct headers & authentication
     *
     * @param method The HTTP method
     * @param url The URL
     * @param data The data to send (optional)
     * @returns The response object
     */
    async sendRequest(method: "GET" | "POST" | "DELETE", url: string, data: Record<string, any> = null) {
        if (!this.authToken) throw new Error("Missing auth token");

        const headers: Record<string, string> = {
            Authorization: `Bearer ${this.authToken}`,
            Accept: "application/json"
        };

        if (["POST", "DELETE"].includes(method) && data) {
            headers["Content-Type"] = "application/json";
        }

        Server().log(`Sending ${method} request to ${url}`, "debug");

        return await axios.request({
            method,
            url,
            headers,
            data
        });
    }

    private async openWindow(url: string, waitForClose = true) {
        return new Promise<void>((resolve, _) => {
            const window = new BrowserWindow({
                width: 800,
                height: 600,
                webPreferences: {
                    nodeIntegration: true
                }
            });

            window.loadURL(url);

            // Open links in the same window
            window.webContents.setWindowOpenHandler((details: HandlerDetails) => {
                window.loadURL(details.url);
                return { action: "deny" };
            });

            if (waitForClose) {
                window.on("closed", () => {
                    resolve();
                });
            } else {
                resolve();
            }
        });
    }

    /**
     * Closes the HTTP server
     */
    private async closeHttp(): Promise<void> {
        return new Promise((resolve, reject): void => {
            if (this.httpServer) {
                this.httpServer.close((err: Error) => {
                    if (err) {
                        reject(err);
                    } else {
                        resolve(null);
                    }
                });
            } else {
                resolve(null);
            }
        });
    }

    /**
     * Stops the service
     */
    async stop(): Promise<void> {
        Server().log("Stopping OAuth Service...");
        this.running = false;

        try {
            await this.closeHttp();
        } catch (ex: any) {
            if (ex.message !== "Server is not running.") {
                Server().log(`Failed to close HTTP server: ${ex.message}`);
            }
        }
    }

    /**
     * Restarts the Socket.IO connection with a new port
     *
     * @param port The new port to listen on
     */
    async restart(reinitialize = false): Promise<void> {
        await this.stop();
        if (reinitialize) this.initialize();
        await this.start();
    }
}
