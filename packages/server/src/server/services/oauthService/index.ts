// HTTP libraries
import KoaApp from "koa";
import http from "http";
import axios, { AxiosResponse } from "axios";

// Internal libraries
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import * as admin from "firebase-admin";
import { google, Auth } from "googleapis";
import { generateProjectId } from "@server/utils/CryptoUtils";
import { getObjectAsString, isEmpty, isNotEmpty, waitMs } from "@server/helpers/utils";
import { ProgressStatus } from "@server/types";
import { FCMService } from "../fcmService";
import { BrowserWindow, HandlerDetails } from "electron";
import { Loggable } from "@server/lib/logging/Loggable";
import { ContactInterface } from "@server/api/interfaces/contactInterface";

/**
 * This service class hhandles the initial oauth workflows
 */
export class OauthService extends Loggable {
    tag = "OauthService";

    running = false;

    status: ProgressStatus = ProgressStatus.NOT_STARTED

    koaApp: KoaApp;

    httpServer: http.Server;

    httpOpts: any;

    oauthClient: Auth.OAuth2Client;

    port = 8641;

    authToken: string;

    expiresIn: number;

    projectName = "BlueBubbles";

    private clientId = "500464701389-os4g4b8mfoj86vujg4i61dmh9827qbrv.apps.googleusercontent.com";

    private _packageName = "com.bluebubbles.messaging";

    private firebaseScopes = [
        "https://www.googleapis.com/auth/cloudplatformprojects",
        "https://www.googleapis.com/auth/service.management",
        "https://www.googleapis.com/auth/firebase",
        "https://www.googleapis.com/auth/datastore",
        "https://www.googleapis.com/auth/iam"
    ];

    private contactScopes = [
        "https://www.googleapis.com/auth/contacts.readonly"
    ]

    /**
     * APIs the project needs, enabled in one batch. Enabling one that is already on is a no-op.
     * iam.googleapis.com is what minting the Admin SDK key needs; it used to be left off.
     */
    private requiredServices = [
        "cloudapis.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "iam.googleapis.com",
        "firebase.googleapis.com",
        "firestore.googleapis.com"
    ];

    get callbackUrl(): string {
        return `http://localhost:${this.port}/oauth/callback`;
    }

    constructor() {
        super();
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
                this.log.info("Received OAuth callback");
                ctx.body = "Success! You can close this window and return to the BlueBubbles Server app";
                ctx.status = 200;
            } else {
                ctx.body = "Not found";
                ctx.status = 404;
            }
        });
    }

    setStatus(status: ProgressStatus) {
        this.status = status;
        Server().emitToUI("oauth-status", status);
    }

    /**
     * Handles the project creation workflow.
     * When the flow is complete, the JSON files will be saved to the resources folder.
     * The service will then stop itself upon successful completion.
     */
    async handleProjectCreation() {
        try {
            this.setStatus(ProgressStatus.IN_PROGRESS);

            this.log.info(`Creating Google Cloud project, "${this.projectName}"...`);
            const project = await this.runStep("creating the Google Cloud project", () =>
                this.createGoogleCloudProject()
            );
            const projectId = project?.projectId;
            if (!projectId) {
                throw new Error(`Project "${this.projectName}" was not found! Please restart the setup process.`);
            }

            await this.runStep("enabling the required APIs", () => this.enableRequiredServices(projectId));

            this.log.info(`Adding Firebase to Google Cloud Project`);
            await this.runStep("adding Firebase", () => this.addFirebase(projectId));

            this.log.info(`Creating Firestore...`);
            await this.runStep("creating the database", () => this.createDatabase(projectId));

            this.log.info(`Creating Android Configuration...`);
            const appName = await this.runStep("registering the app", () => this.createAndroidApp(projectId));

            this.log.info(`Generating Google Services JSON (this may take some time)...`);
            const servicesJson = await this.runStep("fetching the client configuration", () =>
                this.getGoogleServicesJson(appName)
            );

            // Before the configurations are saved, so the server never starts
            // against a project whose rules were not applied.
            this.log.info(`Creating Firestore Security Rules...`);
            await this.runStep("applying security rules", () => this.createSecurityRules(projectId));

            // Last, because every key minted is a live credential that is only kept if setup
            // completes: a failure in any earlier step must not leave an orphaned key behind.
            this.log.info(`Waiting for Service Account to generate (this may take some time)...`);
            const serviceAccountJson = await this.runStep("generating credentials", () =>
                this.getServiceAccount(projectId)
            );

            // Check if the current firebase server config is different from the previous.
            // If it is, we should log a warning and clear the devices.
            const serverFcm = FileSystem.getFCMServer();
            if (serverFcm?.project_id != null && serviceAccountJson?.project_id !== serverFcm?.project_id) {
                this.log.warn(
                    "Detected change in Firebase project! Clearing devices to prevent notification conflicts. " +
                        "You may need to re-register your devices to receive notifications."
                );

                await Server().repo.devices().clear();
            }

            // Save the configurations
            FileSystem.saveFCMServer(serviceAccountJson);
            FileSystem.saveFCMClient(servicesJson);

            this.log.info(`Revoking OAuth token, to prevent further use...`);
            try {
                await this.oauthClient.revokeToken(this.authToken);
            } catch {
                // Do nothing
            }

            // Wait 10 seconds to ensure credentials propogate
            this.log.info(`Ensuring credentials are propogated..`);
            await waitMs(10000);

            // Mark the service as completed
            this.log.info(
                `Successfully created and configured your Google Project! ` + `You may now continue with setup.`
            );
            this.setStatus(ProgressStatus.COMPLETED);

            // Start the FCM service.
            // Don't await because we don't want to catch the error here.
            FCMService.stop()
                .then(async () => {
                    await waitMs(10000);

                    // Clear our markers & start the service
                    await Server().fcm.clearConfig();
                    await Server().fcm.start();
                })
                .catch(async err => {
                    this.log.debug("An issue occurred when stopping the FCM service after OAuth completion!");
                    this.log.debug(err?.message ?? String(err));
                });
        } catch (ex: any) {
            this.log.error(`Failed to create project: ${ex?.message}`);
            if (ex?.response?.data?.error) {
                this.log.debug(`(${ex.response.data.error.code}) ${ex.response.data.error.message}`);
            }

            this.log.debug(`Use the Google Login button and try again. If the issue persists, please contact support.`);
            this.setStatus(ProgressStatus.FAILED);
        } finally {
            // Shutdown the service
            await this.stop();
        }
    }

    /**
     * Runs one project creation step, naming it in the log if it fails.
     * Without this, a failure surfaces as a bare HTTP error and working out
     * which step was in progress means reading its URL.
     *
     * @param step What the step is doing, for the log
     * @param body The step itself
     * @returns Whatever the step returns
     */
    private async runStep<T>(step: string, body: () => Promise<T>): Promise<T> {
        try {
            return await body();
        } catch (ex: any) {
            this.log.error(`Project setup failed while ${step}: ${this.describeError(ex)}`);
            throw ex;
        }
    }

    async handleContactsSync() {
        try {
            this.setStatus(ProgressStatus.IN_PROGRESS);

            this.log.info(`Fetching Google Contacts...`);
            const contacts = await this.fetchContacts();

            this.log.info(`Saving ${contacts.length} contact(s) to the server...`);
            let errored = false;
            for (const contact of contacts) {
                if (isEmpty(contact.names)) continue;

                try {
                    const avatar = await this.loadContactAvatar(contact);

                    await ContactInterface.createContact({
                        firstName: contact.names[0].givenName,
                        lastName: contact.names[0].familyName,
                        displayName: contact.names[0].displayName,
                        phoneNumbers: (contact.phoneNumbers ?? []).map((p: any) => p.canonicalForm ?? p.value),
                        emails: (contact.emailAddresses ?? []).map((e: any) => e.value),
                        updateEntry: true,
                        avatar
                    });
                } catch (ex: any) {
                    errored = true;
                    this.log.debug(`Failed to save contact: ${ex?.message}`);
                }
            }

            if (errored) {
                this.log.warn(`Some contacts failed to save. Please check the server logs for more information.`);
            }

            this.log.info(`Finished saving contacts to the server!`);

            try {
                this.log.info(`Revoking OAuth token, to prevent further use...`);
                await this.oauthClient.revokeToken(this.authToken);
            } catch {
                // Do nothing
            }

            // Mark the service as completed
            this.log.info('Successfully synced your Google Contacts to the BlueBubbles Server!');
            this.setStatus(ProgressStatus.COMPLETED);

            // Shutdown the service
            await this.stop();
        } catch (ex: any) {
            this.log.error(`Failed to sync contacts: ${ex?.message}`);
            if (ex?.response?.data?.error) {
                this.log.debug(`(${ex.response.data.error.code}) ${ex.response.data.error.message}`);
            }

            this.log.debug(`Use the Google Login button and try again. If the issue persists, please contact support.`);
            this.setStatus(ProgressStatus.FAILED);
        } finally {
            // Shutdown the service
            await this.stop();
        }
    }

    /**
     * Generates the OAuth URL for the client/UI to use.
     *
     * @returns The OAuth URL
     */
    async getFirebaseOauthUrl() {
        const url = await this.oauthClient.generateAuthUrl({
            scope: this.firebaseScopes,
            response_type: "token"
        });

        return `${url}&type=firebase`;
    }

    /**
     * Generates the OAuth URL for the client/UI to use.
     *
     * @returns The OAuth URL
     */
    async getContactsOauthUrl() {
        const url = await this.oauthClient.generateAuthUrl({
            scope: this.contactScopes,
            response_type: "token"
        });

        return `${url}&type=contacts`;
    }

    /**
     * Starts the HTTP server
     */
    start() {
        this.log.info("Starting OAuth Service...");
        this.running = true;

        // Start the server
        this.httpServer.listen(this.port, () => {
            this.log.info(`Successfully started OAuth2 server`);
        });
    }

    async checkIfProjectExists() {
        // eslint-disable-next-line max-len
        const getUrl = `https://cloudresourcemanager.googleapis.com/v1/projects?filter=name%3A${this.projectName}%20AND%20lifecycleState%3AACTIVE`;
        const getRes = await this.sendRequest("GET", getUrl);

        // Check if the project already exists and return the data if it does
        const projectMatch = (getRes.data?.projects ?? []).length > 0;
        if (projectMatch) {
            this.log.info(`Project "${this.projectName}" already exists!`);
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
            projectId = generateProjectId(this.projectName);
            const data = { name: this.projectName, projectId };
            this.log.info(`Creating project with name, "${this.projectName}", under project ID, "${projectId}"`);
            const createRes = await this.tryUntilNoError("POST", postUrl, data, 3, 5000);

            // Wait for the operation to complete (try for 2 minutes)
            const operationName = createRes.name;
            const operationUrl = `https://cloudresourcemanager.googleapis.com/v1/${operationName}`;
            return await this.waitForData("GET", operationUrl, null, "done", 60, 5000);
        };

        let operationData = await createProj();

        // If there is an error, throw it
        if (isNotEmpty(operationData?.error)) {
            const isTosError = operationData.error.message.includes("Terms of Service");
            if (isTosError) {
                this.log.info(
                    `You must accept the Google Cloud Terms of Service before continuing! ` +
                        `A window will open in 10 seconds for you to accept the TOS. ` +
                        `Once you accept the TOS, you can close the window and setup will continue.`
                );

                await waitMs(10000);
                await this.openWindow("https://console.cloud.google.com/projectcreate");
            } else {
                throw new Error(`Error: ${getObjectAsString(operationData.error)}`);
            }

            // Try again
            this.log.info(`Retrying project creation...`);
            operationData = await createProj();
        }

        // Throw an error if a project ID isn't returned
        if (isEmpty(operationData?.response?.projectId)) {
            throw new Error(`No Project ID was returned!`);
        }

        // Fetch the project data
        // eslint-disable-next-line max-len
        const getUrl = `https://cloudresourcemanager.googleapis.com/v1/projects?filter=name%3A${this.projectName}%20AND%20lifecycleState%3AACTIVE`;
        const projectData = await this.waitForData(
            "GET",
            getUrl,
            null,
            "projects",
            12, 10000,  // Wait at least 2 minutes
            `Project "${this.projectName}" was not found! Please restart the setup process.`
        );
        return (projectData.projects ?? []).find((p: any) => p.projectId === projectId);
    }

    /**
     * Enables every required API in one call.
     * One batch returns a single operation, rather than a POST and a polling loop per service.
     *
     * @param projectId The project ID
     */
    async enableRequiredServices(projectId: string) {
        this.log.info(`Enabling the required Google Cloud APIs: ${this.requiredServices.join(", ")}`);
        const url = `https://serviceusage.googleapis.com/v1/projects/${projectId}/services:batchEnable`;
        const operation = await this.tryUntilNoError("POST", url, { serviceIds: this.requiredServices }, 5, 5000);
        await this.awaitOperation(operation, "https://serviceusage.googleapis.com/v1", "enabling the required APIs");
    }

    /**
     * Adds Firebase to the Google Cloud Project
     *
     * @param projectId The project ID
     * @throws An HTTP error if the error code is not 409
     */
    async addFirebase(projectId: string) {
        try {
            // Try for at least 2 minutes (8 attempts with 15 second delay)
            const url = `https://firebase.googleapis.com/v1beta1/projects/${projectId}:addFirebase`;
            const operation = await this.tryUntilNoError("POST", url, {}, 8, 15000);
            await this.awaitOperation(operation, "https://firebase.googleapis.com/v1beta1", "adding Firebase");
            await waitMs(5000); // Wait 5 seconds to ensure Firebase is ready
        } catch (ex: any) {
            if (ex.response?.data?.error?.code === 409) {
                this.log.info(`Firebase already exists!`);
            } else if (ex.response?.data?.error?.code === 403) {
                await this.addFirebaseManual();
            } else {
                this.log.debug(`Failed to add Firebase to project: Data: ${getObjectAsString(ex.response?.data)}`);
                throw new Error(
                    `Failed to add Firebase to project: ${getObjectAsString(
                        ex.response?.data?.error?.message ?? ex.message
                    )}}`
                );
            }
        }
    }

    async addFirebaseManual() {
        this.log.info(
            `You must manually create the Firebase project! In 10 seconds, ` +
                `a window will open where you can create a new project. ` +
                `Select your existing BlueBubbles Resource and add Firebase to the project. ` +
                `Once the project is created, you can close the window and setup will continue.`
        );

        await waitMs(10000);
        await this.openWindow(`https://console.firebase.google.com/`);
        this.log.info(`Resuming setup...`);
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
            const res = await this.sendRequest("POST", url, data);
            await this.awaitOperation(res.data, "https://firestore.googleapis.com/v1", "creating Firestore");
        } catch (ex: any) {
            const error = ex.response?.data?.error;
            if (error?.code === 409 || error?.status === "ALREADY_EXISTS") {
                this.log.info(`Firestore already exists!`);
                return;
            }

            // Google will not create a database on a project with no billing account. Matched on
            // the message, because it arrives as PERMISSION_DENIED, FAILED_PRECONDITION or a plain
            // 400 depending on the account, and Google's own wording does not say what to do.
            const message = String(error?.message ?? ex?.message ?? "");
            if (message.toLowerCase().includes("billing")) {
                throw new Error(
                    `Google requires a billing account on project ${projectId} before it will create a ` +
                        `Firestore database. Enable billing on that project, then run setup again; it will ` +
                        `continue with the same project. Cloud Messaging is free and this server's database ` +
                        `usage is negligible.`
                );
            }

            throw ex;
        }
    }

    /**
     * Creates an Android app configuration for the Google Cloud Project,
     * or finds the one that already exists for our package name.
     *
     * @param projectId The project ID
     * @returns The app's resource name (projects/{project}/androidApps/{appId})
     * @throws An HTTP error if the error code is not 409
     */
    async createAndroidApp(projectId: string): Promise<string> {
        // Checked first: registering a second app for the same package name creates a duplicate
        // whose google-services.json may not be the one clients are using.
        const existing = await this.findAndroidApp(projectId);
        if (existing) {
            this.log.info(`Android Configuration already exists!`);
            return existing;
        }

        try {
            const url = `https://firebase.googleapis.com/v1beta1/projects/${projectId}/androidApps`;
            const data = { displayName: this.projectName, packageName: this.packageName };
            const res = await this.tryUntilNoError("POST", url, data, 3, 10000);

            // Checked before polling: when Google answers with the created app rather than an
            // operation, polling the app's own URL as an operation would only time out.
            const immediate = this.androidAppName(res);
            if (immediate) return immediate;

            const operation = await this.awaitOperation(
                res,
                "https://firebase.googleapis.com/v1beta1",
                "registering the app"
            );
            const created = this.androidAppName(operation);
            if (created) return created;
        } catch (ex: any) {
            if (ex.response?.data?.error?.code !== 409) throw ex;
            this.log.info(`Android Configuration already exists!`);
        }

        const appName = await this.findAndroidApp(projectId);
        if (!appName) throw new Error(`Could not find the Android app for package name ${this.packageName}`);
        return appName;
    }

    /**
     * Finds the project's Android app for our package name
     *
     * @param projectId The project ID
     * @returns The app's resource name, or null if there is none (or the listing failed)
     */
    private async findAndroidApp(projectId: string): Promise<string> {
        try {
            const url = `https://firebase.googleapis.com/v1beta1/projects/${projectId}/androidApps`;
            const res = await this.sendRequest("GET", url);
            return (res.data?.apps ?? []).find((app: any) => app.packageName === this.packageName)?.name ?? null;
        } catch (ex: any) {
            // Not fatal: attempting the registration explains a real problem better than aborting here
            this.log.debug(`Could not read the project's existing apps: ${this.describeError(ex)}`);
            return null;
        }
    }

    /**
     * The projects/{project}/androidApps/{appId} resource name, wherever it is in a payload.
     * Guarded on the path, because an operation's own name is operations/...
     *
     * @param payload An app, or a finished operation wrapping one
     * @returns The resource name, or null
     */
    private androidAppName(payload: any): string {
        for (const name of [payload?.response?.name, payload?.name]) {
            if (typeof name === "string" && name.includes("/androidApps/")) return name;
        }

        return null;
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
     * Finds the project's Firebase Admin service account.
     *
     * Matched on the display name or the email prefix: Google appends a suffix to the address
     * (firebase-adminsdk-a1b2c@ historically, firebase-adminsdk-fbsvc@ on newer projects), and
     * the display name could change. The account is created by addFirebase, but not instantly.
     *
     * @param projectId The project ID
     * @returns The account's unique ID (or email) and email, or null if it never appeared
     */
    async getFirebaseServiceAccount(projectId: string): Promise<{ id: string; email: string }> {
        const url = `https://iam.googleapis.com/v1/projects/${projectId}/serviceAccounts`;
        let lastError: string = null;

        // Max wait time: 5 minutes (60 attempts with 5 second delay)
        for (let attempt = 0; attempt < 60; attempt++) {
            try {
                const res = await this.sendRequest("GET", url);
                const match = (res.data?.accounts ?? []).find(
                    (account: any) =>
                        account.displayName === "firebase-adminsdk" || account.email?.startsWith("firebase-adminsdk")
                );

                const id = match?.uniqueId ?? match?.email;
                if (id) return { id, email: match.email };
            } catch (ex: any) {
                // Retried rather than fatal: the IAM API was enabled moments ago
                // and can briefly refuse calls while that propagates.
                lastError = this.describeError(ex);
            }

            await waitMs(5000);
        }

        this.log.debug(`The Firebase Admin service account never appeared. Last error: ${lastError ?? "none"}`);
        return null;
    }

    /**
     * Mints a new key for the project's Firebase Admin service account.
     *
     * Additive: existing keys stay valid, so another server using this project keeps working.
     * This used to delete every user-managed key first, which broke any other server holding one,
     * and left the project with no usable key at all if the mint then failed.
     *
     * @param projectId The project ID
     * @returns The service account private key JSON
     */
    async getServiceAccount(projectId: string) {
        const account = await this.getFirebaseServiceAccount(projectId);
        if (!account) {
            throw new Error(
                "The project's Firebase Admin service account did not appear. " +
                    "This is usually temporary; try again in a few minutes."
            );
        }

        const url = `https://iam.googleapis.com/v1/projects/${projectId}/serviceAccounts/${account.id}/keys`;
        const data = { privateKeyType: "TYPE_GOOGLE_CREDENTIALS_FILE" };

        // Retried only while Google refuses in a way that means "not yet". Every successful POST
        // creates a live private key, and Google allows ten per account, so nothing retries once
        // a key has been returned.
        let lastRefusal: any = null;
        for (let attempt = 1; attempt <= 12; attempt++) {
            let response: AxiosResponse<any, any>;
            try {
                response = await this.sendRequest("POST", url, data);
            } catch (ex: any) {
                if (!this.isNotReadyYet(ex)) {
                    if (ex.response?.status === 400) {
                        throw new Error(
                            `Google refused to create a service account key: ${this.describeError(ex)}. ` +
                                `If ${account.email ?? "the firebase-adminsdk account"} already has 10 keys, ` +
                                `delete unused ones in the Google Cloud console (IAM & Admin > Service Accounts), ` +
                                `then run setup again.`
                        );
                    }

                    throw ex;
                }

                lastRefusal = ex;
                this.log.debug(
                    `The service account is not ready yet; waiting (attempt ${attempt}): ${this.describeError(ex)}`
                );
                await waitMs(5000);
                continue;
            }

            const privateKeyData = Buffer.from(response.data.privateKeyData, "base64").toString("utf-8");
            return JSON.parse(privateKeyData);
        }

        throw lastRefusal ?? new Error("Failed to create a service account key!");
    }

    /**
     * Whether a refused request may be asked again: Google has not done anything,
     * and the refusal is one that changes with time (propagation, rate limits, outages).
     * A 400 is not: it is the key limit or a malformed request, and waiting fixes neither.
     *
     * @param ex The error from sendRequest
     */
    private isNotReadyYet(ex: any): boolean {
        if (!axios.isAxiosError(ex)) return false;

        // No response at all: the connection, not a refusal
        const status = ex.response?.status;
        if (status == null) return true;
        return [403, 404, 409, 429].includes(status) || status >= 500;
    }

    /**
     * Describes an error, using Google's own message when there is one
     *
     * @param ex The error
     */
    private describeError(ex: any): string {
        const error = ex?.response?.data?.error;
        if (error?.message) return `(${error.code ?? ex.response.status}) ${error.message}`;
        return ex?.message ?? String(ex);
    }

    /**
     * Gets the Google Services JSON from the Google Cloud Project (Android Config)
     *
     * @param appName The app's resource name (projects/{project}/androidApps/{appId})
     * @returns The Google Services JSON string
     */
    async getGoogleServicesJson(appName: string) {
        const cfgUrl = `https://firebase.googleapis.com/v1beta1/${appName}/config`;
        const cfgRes = await this.sendRequest("GET", cfgUrl);
        const b64Config = cfgRes.data.configFileContents;
        const config = Buffer.from(b64Config, "base64").toString("utf-8");
        return JSON.parse(config);
    }

    /**
     * Polls a long-running operation until it finishes.
     *
     * Operations are polled on the service that issued them: serviceusage operations live under
     * serviceusage.googleapis.com, Firebase's under firebase.googleapis.com, and so on. The interval
     * escalates from 500ms to 3s, since most of these finish within a second or two.
     *
     * @param operation The operation a call returned
     * @param host The API base the operation belongs to
     * @param step What the operation is doing, for errors
     * @param timeoutMs How long to wait before giving up
     * @returns The finished operation, or null if there was nothing to wait for
     */
    async awaitOperation(operation: any, host: string, step: string, timeoutMs = 180000): Promise<any> {
        if (operation?.done === true) return operation;

        // Service Usage answers an already-enabled API with this sentinel instead of a real operation
        const name: string = operation?.name;
        if (!name || name.endsWith("DONE_OPERATION")) return null;

        const deadline = Date.now() + timeoutMs;
        let delay = 500;
        while (Date.now() < deadline) {
            await waitMs(delay);
            const res = await this.sendRequest("GET", `${host}/${name}`);
            if (res.data?.done === true) {
                if (res.data.error) {
                    const reason = res.data.error.message ?? getObjectAsString(res.data.error);
                    throw new Error(`Google could not finish ${step}: ${reason}`);
                }

                return res.data;
            }

            delay = Math.min(delay + 500, 3000);
        }

        throw new Error(
            `Google did not finish ${step} in time. The project may still be created; ` +
                `check the Firebase console before trying again.`
        );
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
        waitTime = 2000,
        errorOverride: string = null
    ) {
        let attempts = 0;

        // eslint-disable-next-line no-constant-condition
        while (true) {
            const res = await this.sendRequest(method, url, data);
            if (!key && isNotEmpty(res.data)) return res.data;
            if (key && isNotEmpty(res.data[key])) return res.data;

            attempts += 1;
            if (attempts > maxAttempts) {
                this.log.debug(`Received data from failed request: ${getObjectAsString(res.data)}`);
                throw new Error(errorOverride ??
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
    async tryUntilNoError(method: "GET" | "POST", url: string, data: Record<string, any> = null, maxAttempts = 30, waitTime = 2000) {
        let attempts = 0;

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

    async fetchContacts() {
        // Fetch the project data
        // eslint-disable-next-line max-len
        const getUrl = `https://people.googleapis.com/v1/people/me/connections`;
        const params = {
            personFields: "names,emailAddresses,phoneNumbers,nicknames,photos"
        };

        // Paginate through all the data
        let pageToken = null;
        let contacts = [];
        do {
            const res: AxiosResponse<any, any> = await this.sendRequest("GET", getUrl, null, { ...params, pageToken });
            contacts.push(...res.data.connections);
            pageToken = res.data.nextPageToken;
        } while (pageToken);

        return contacts;
    }

    async loadContactAvatar(contact: any): Promise<Buffer> {
        let photoUrl: string = null;

        // Load the avatar for the user (if available).
        // First try the primary, and if that doesn't exist, use the first.
        const primary = (contact.photos ?? []).find((p: any) => p.metadata?.primary);
        if (primary) {
            photoUrl = primary.url;
        } else if (isNotEmpty(contact.photos)) {
            photoUrl = contact.photos[0].url;
        }

        if (photoUrl) {
            // Replace the size (100) with size 240 + some flags
            photoUrl = photoUrl.replace("s100", "s240-p-k-rw-no");
            try {
                const avatar = await axios.get(photoUrl, { responseType: "arraybuffer" });
                return avatar?.data;
            } catch {
                // Do nothing
            }
        }

        return null;
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
    async sendRequest(method: "GET" | "POST" | "DELETE", url: string, data: Record<string, any> = null, params: Record<string, any> = null) {
        if (!this.authToken) throw new Error("Missing auth token");

        const headers: Record<string, string> = {
            Authorization: `Bearer ${this.authToken}`,
            Accept: "application/json"
        };

        if (["POST", "DELETE"].includes(method) && data) {
            headers["Content-Type"] = "application/json";
        }

        this.log.debug(`Sending ${method} request to ${url}`);

        return await axios.request({
            method,
            url,
            params,
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
        this.log.info("Stopping OAuth Service...");
        this.running = false;

        try {
            await this.closeHttp();
        } catch (ex: any) {
            if (ex.message !== "Server is not running.") {
                this.log.info(`Failed to close HTTP server: ${ex.message}`);
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
