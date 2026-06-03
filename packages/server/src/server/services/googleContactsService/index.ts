import axios from "axios";
import { google, Auth, people_v1 } from "googleapis";
import { Server } from "@server";
import { Loggable } from "@server/lib/logging/Loggable";
import { ContactInterface } from "@server/api/interfaces/contactInterface";
import { Contact } from "@server/databases/server/entity/Contact";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";

/**
 * The built-in, shared BlueBubbles OAuth client. This is a public client with
 * no secret. Whether Google will issue a refresh token for it via the
 * authorization-code + PKCE flow (approach "A") is determined at runtime; if it
 * does not, the user can provide their own OAuth client (approach "B") by
 * setting `google_oauth_client_id` / `google_oauth_client_secret` in config.
 */
export const BUILTIN_GOOGLE_CLIENT_ID =
    "500464701389-os4g4b8mfoj86vujg4i61dmh9827qbrv.apps.googleusercontent.com";

/** The loopback redirect URI used for the interactive OAuth consent. */
export const GOOGLE_OAUTH_REDIRECT_URI = "http://localhost:8641/oauth/callback";

/** The person fields we request from the People API. */
export const GOOGLE_CONTACTS_PERSON_FIELDS = "names,emailAddresses,phoneNumbers,nicknames,photos";

export interface GoogleOAuthClientConfig {
    clientId: string;
    clientSecret: string | null;
}

/**
 * Resolves which OAuth client to use. If the user has provided their own client
 * (approach "B"), that takes precedence; otherwise we fall back to the built-in
 * shared client (approach "A").
 */
export const resolveGoogleOAuthClientConfig = (): GoogleOAuthClientConfig => {
    const cfgId = (Server().repo?.getConfig("google_oauth_client_id") as string) ?? "";
    const cfgSecret = (Server().repo?.getConfig("google_oauth_client_secret") as string) ?? "";
    if (isNotEmpty(cfgId)) {
        return { clientId: cfgId, clientSecret: isNotEmpty(cfgSecret) ? cfgSecret : null };
    }

    return { clientId: BUILTIN_GOOGLE_CLIENT_ID, clientSecret: null };
};

export interface GoogleContactsSyncStats {
    added: number;
    updated: number;
    deleted: number;
}

export interface GoogleContactsStatus {
    enabled: boolean;
    connected: boolean;
    syncing: boolean;
    interval: number;
    lastSync: number;
    usingCustomClient: boolean;
}

/**
 * Keeps the local contact database in sync with the user's Google Contacts.
 *
 * - Holds an OAuth2 client seeded with a stored refresh token (offline access),
 *   so it can fetch contacts in the background without further user interaction.
 * - Performs incremental syncs using the People API sync token, applying both
 *   upserts and deletions, keyed on `externalId` (the Google `resourceName`).
 * - Owns the periodic scheduler.
 */
export class GoogleContactsService extends Loggable {
    tag = "GoogleContactsService";

    private oauthClient: Auth.OAuth2Client | null = null;

    private syncTimer: NodeJS.Timeout | null = null;

    private syncing = false;

    // ---------------------------------------------------------------------
    // Config-backed accessors
    // ---------------------------------------------------------------------

    get enabled(): boolean {
        return (Server().repo?.getConfig("google_contacts_sync_enabled") as boolean) ?? false;
    }

    get intervalMinutes(): number {
        const value = Number(Server().repo?.getConfig("google_contacts_sync_interval") ?? 360);
        return Number.isFinite(value) && value > 0 ? value : 360;
    }

    get refreshToken(): string {
        return (Server().repo?.getConfig("google_contacts_refresh_token") as string) ?? "";
    }

    get syncToken(): string {
        return (Server().repo?.getConfig("google_contacts_sync_token") as string) ?? "";
    }

    get lastSync(): number {
        return Number(Server().repo?.getConfig("google_contacts_last_sync") ?? 0);
    }

    get isConnected(): boolean {
        return isNotEmpty(this.refreshToken);
    }

    getStatus(): GoogleContactsStatus {
        return {
            enabled: this.enabled,
            connected: this.isConnected,
            syncing: this.syncing,
            interval: this.intervalMinutes,
            lastSync: this.lastSync,
            usingCustomClient: isNotEmpty(Server().repo?.getConfig("google_oauth_client_id") as string)
        };
    }

    // ---------------------------------------------------------------------
    // OAuth client
    // ---------------------------------------------------------------------

    private buildClient(): Auth.OAuth2Client | null {
        if (isEmpty(this.refreshToken)) return null;

        const { clientId, clientSecret } = resolveGoogleOAuthClientConfig();
        const client = new google.auth.OAuth2(clientId, clientSecret ?? undefined, GOOGLE_OAUTH_REDIRECT_URI);
        client.setCredentials({ refresh_token: this.refreshToken });

        // Persist a rotated refresh token if Google ever issues a new one.
        client.on("tokens", async (tokens: Auth.Credentials) => {
            if (tokens.refresh_token) {
                try {
                    await Server().repo.setConfig("google_contacts_refresh_token", tokens.refresh_token);
                } catch (ex: any) {
                    this.log.debug(`Failed to persist rotated refresh token: ${ex?.message ?? String(ex)}`);
                }
            }
        });

        this.oauthClient = client;
        return client;
    }

    // ---------------------------------------------------------------------
    // Lifecycle / scheduling
    // ---------------------------------------------------------------------

    /** Called once on server startup. Schedules background sync if enabled & connected. */
    async start(): Promise<void> {
        if (!this.enabled) {
            this.log.debug("Background sync is disabled; not scheduling.");
            return;
        }

        if (!this.isConnected) {
            this.log.debug("Background sync is enabled but not connected (no refresh token).");
            return;
        }

        this.scheduleTimer();

        // Catch-up sync if we've never synced or we're overdue.
        const due = this.lastSync === 0 || Date.now() - this.lastSync >= this.intervalMinutes * 60_000;
        if (due) {
            this.sync().catch(ex => this.log.error(`Startup sync failed: ${this.describeError(ex)}`));
        }
    }

    private scheduleTimer(): void {
        this.clearTimer();
        const period = this.intervalMinutes * 60_000;
        this.syncTimer = setInterval(() => {
            this.sync().catch(ex => this.log.error(`Scheduled sync failed: ${this.describeError(ex)}`));
        }, period);
        this.log.info(`Scheduled Google Contacts sync every ${this.intervalMinutes} minute(s).`);
    }

    private clearTimer(): void {
        if (this.syncTimer) {
            clearInterval(this.syncTimer);
            this.syncTimer = null;
        }
    }

    /** Re-applies scheduling after an enable/interval change. */
    async restart(): Promise<void> {
        this.clearTimer();
        await this.start();
    }

    async stop(): Promise<void> {
        this.clearTimer();
    }

    async setEnabled(enabled: boolean): Promise<void> {
        await Server().repo.setConfig("google_contacts_sync_enabled", enabled);
        await this.restart();
    }

    async setSyncInterval(minutes: number): Promise<void> {
        await Server().repo.setConfig("google_contacts_sync_interval", minutes);
        await this.restart();
    }

    // ---------------------------------------------------------------------
    // Connect / disconnect
    // ---------------------------------------------------------------------

    /**
     * Called after a successful interactive consent that yielded a refresh token.
     * Stores the token, enables sync, and performs an immediate full sync.
     */
    async connectWithRefreshToken(refreshToken: string): Promise<void> {
        await Server().repo.setConfig("google_contacts_refresh_token", refreshToken);
        // New connection → reset the sync token to force a full sync.
        await Server().repo.setConfig("google_contacts_sync_token", "");
        await Server().repo.setConfig("google_contacts_sync_enabled", true);

        this.buildClient();
        this.scheduleTimer();

        await this.syncNow(true);
    }

    /** Revokes & clears stored tokens and stops scheduling. */
    async disconnect(): Promise<void> {
        this.clearTimer();

        try {
            const client = this.oauthClient ?? this.buildClient();
            if (client && isNotEmpty(this.refreshToken)) {
                await client.revokeToken(this.refreshToken);
            }
        } catch (ex: any) {
            this.log.debug(`Failed to revoke Google token: ${ex?.message ?? String(ex)}`);
        }

        this.oauthClient = null;
        await Server().repo.setConfig("google_contacts_refresh_token", "");
        await Server().repo.setConfig("google_contacts_sync_token", "");
        await Server().repo.setConfig("google_contacts_sync_enabled", false);
        this.log.info("Disconnected Google Contacts sync.");
    }

    // ---------------------------------------------------------------------
    // Sync
    // ---------------------------------------------------------------------

    async syncNow(force = false): Promise<GoogleContactsSyncStats> {
        return await this.sync(force);
    }

    private async sync(_force = false): Promise<GoogleContactsSyncStats> {
        if (this.syncing) {
            this.log.debug("A sync is already in progress; skipping.");
            return { added: 0, updated: 0, deleted: 0 };
        }

        if (!this.isConnected) {
            throw new Error("Google Contacts is not connected (no refresh token).");
        }

        this.syncing = true;
        const client = this.oauthClient ?? this.buildClient();
        const people = google.people({ version: "v1", auth: client });
        const stats: GoogleContactsSyncStats = { added: 0, updated: 0, deleted: 0 };

        try {
            let nextSyncToken: string | undefined;

            const runPass = async (withSyncToken: boolean): Promise<void> => {
                let pageToken: string | undefined;
                do {
                    const res = await people.people.connections.list({
                        resourceName: "people/me",
                        personFields: GOOGLE_CONTACTS_PERSON_FIELDS,
                        pageSize: 1000,
                        pageToken,
                        requestSyncToken: true,
                        syncToken: withSyncToken ? this.syncToken : undefined
                    });

                    const connections = res.data.connections ?? [];
                    for (const person of connections) {
                        if (person.metadata?.deleted) {
                            if (await this.deletePerson(person)) stats.deleted += 1;
                        } else {
                            const result = await this.upsertPerson(person);
                            if (result === "added") stats.added += 1;
                            else if (result === "updated") stats.updated += 1;
                        }
                    }

                    pageToken = res.data.nextPageToken ?? undefined;
                    nextSyncToken = res.data.nextSyncToken ?? nextSyncToken;
                } while (pageToken);
            };

            const useSyncToken = isNotEmpty(this.syncToken);
            try {
                this.log.info(
                    useSyncToken
                        ? "Performing incremental Google Contacts sync..."
                        : "Performing full Google Contacts sync..."
                );
                await runPass(useSyncToken);
            } catch (ex: any) {
                // An expired sync token returns HTTP 410 (GONE). Reset & full resync.
                const code = ex?.code ?? ex?.response?.status;
                if (code === 410 || code === "410") {
                    this.log.info("Google sync token expired; performing a full resync.");
                    await Server().repo.setConfig("google_contacts_sync_token", "");
                    nextSyncToken = undefined;
                    await runPass(false);
                } else {
                    this.log.error(`Google Contacts sync failed: ${this.describeError(ex)}`);
                    throw ex;
                }
            }

            if (isNotEmpty(nextSyncToken)) {
                await Server().repo.setConfig("google_contacts_sync_token", nextSyncToken);
            }
            await Server().repo.setConfig("google_contacts_last_sync", Date.now());

            this.log.info(
                `Google Contacts sync complete. Added ${stats.added}, updated ${stats.updated}, ` +
                    `deleted ${stats.deleted}.`
            );
            return stats;
        } finally {
            this.syncing = false;
        }
    }

    // ---------------------------------------------------------------------
    // Per-person helpers
    // ---------------------------------------------------------------------

    private async upsertPerson(person: people_v1.Schema$Person): Promise<"added" | "updated" | "skipped"> {
        if (isEmpty(person.names)) return "skipped";

        const externalId = person.resourceName ?? undefined;
        const name = person.names[0];
        const firstName = name.givenName ?? "";
        const lastName = name.familyName ?? "";
        const displayName = name.displayName ?? "";
        const phoneNumbers = (person.phoneNumbers ?? [])
            .map((p: any) => p.canonicalForm ?? p.value)
            .filter((p: any) => isNotEmpty(p));
        const emails = (person.emailAddresses ?? []).map((e: any) => e.value).filter((e: any) => isNotEmpty(e));
        const avatar = await this.loadAvatar(person);

        // Find by externalId; if not found (e.g. contacts created by the older
        // name-based sync), fall back to a name match and backfill the externalId.
        let existing: Contact | null = null;
        if (isNotEmpty(externalId)) {
            existing = await ContactInterface.findDbContact({ externalId, throwError: false });
        }
        if (!existing) {
            existing = await this.findByName(firstName, lastName, displayName);
        }

        try {
            await ContactInterface.createOrUpdateContact({
                id: existing?.id,
                externalId,
                firstName,
                lastName,
                displayName,
                phoneNumbers,
                emails,
                avatar: avatar ?? null,
                updateEntry: true
            });
            return existing ? "updated" : "added";
        } catch (ex: any) {
            this.log.debug(`Failed to upsert contact "${displayName || firstName}": ${ex?.message ?? String(ex)}`);
            return "skipped";
        }
    }

    private async deletePerson(person: people_v1.Schema$Person): Promise<boolean> {
        const externalId = person.resourceName ?? undefined;
        if (isEmpty(externalId)) return false;

        try {
            await ContactInterface.deleteContact({ externalId });
            return true;
        } catch {
            // The contact may not exist locally; ignore.
            return false;
        }
    }

    private async findByName(firstName: string, lastName: string, displayName: string): Promise<Contact | null> {
        if (isEmpty(firstName) && isEmpty(lastName) && isEmpty(displayName)) return null;

        const where: Record<string, string> = {};
        if (isNotEmpty(firstName)) where.firstName = firstName;
        if (isNotEmpty(lastName)) where.lastName = lastName;
        if (isNotEmpty(displayName)) where.displayName = displayName;

        return await Server()
            .repo.contacts()
            .findOne({ where, relations: { addresses: true } });
    }

    /** Extracts a human-readable message from a googleapis / Gaxios error. */
    private describeError(ex: any): string {
        return (
            ex?.response?.data?.error?.message ??
            ex?.response?.data?.error_description ??
            (typeof ex?.response?.data?.error === "string" ? ex.response.data.error : null) ??
            ex?.errors?.[0]?.message ??
            ex?.message ??
            String(ex)
        );
    }

    private async loadAvatar(person: people_v1.Schema$Person): Promise<Buffer | null> {
        const photos = (person.photos ?? []) as any[];
        // Skip Google's generic silhouette/default photos.
        const usable = photos.filter(p => !p.default);

        let photoUrl: string | null = null;
        const primary = usable.find(p => p.metadata?.primary);
        if (primary) {
            photoUrl = primary.url;
        } else if (isNotEmpty(usable)) {
            photoUrl = usable[0].url;
        }

        if (isEmpty(photoUrl)) return null;

        // Request a larger image than the default 100px.
        photoUrl = photoUrl.replace("s100", "s240-p-k-rw-no");
        try {
            const res = await axios.get(photoUrl, { responseType: "arraybuffer" });
            return res?.data ?? null;
        } catch {
            return null;
        }
    }
}
