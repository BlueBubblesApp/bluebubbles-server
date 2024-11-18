import fs from "fs";
import { app } from "electron";
import { EventEmitter } from "events";
import { DataSource } from "typeorm";
import { Server } from "@server";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { Config, Alert, Device, Queue, Webhook, Contact, ContactAddress, ScheduledMessage } from "./entity";
import { DEFAULT_DB_ITEMS } from "./constants";
import { ContactTables1654432080899 } from "./migrations/1654432080899-ContactTables";
import { ScheduledMessageTable1665083072000 } from "./migrations/1665083072000-ScheduledMessageTable";

export type ServerConfig = { [key: string]: Date | string | boolean | number };
export type ServerConfigChange = { prevConfig: ServerConfig; nextConfig: ServerConfig };

export class ServerRepository extends EventEmitter {
    db: DataSource = null;

    config: ServerConfig;

    constructor() {
        super();

        this.db = null;
        this.config = {};
    }

    async initialize(): Promise<DataSource> {
        const isDev = process.env.NODE_ENV !== "production";

        // If the DB is set, but not connected, try to connect
        if (this.db) {
            if (!this.db.isInitialized) await this.db.initialize();
            return this.db;
        }

        let dbPath = `${app.getPath("userData")}/config.db`;
        if (isDev) {
            dbPath = `${app.getPath("userData")}/bluebubbles-server/config.db`;
        }

        const shouldSync = !fs.existsSync(dbPath) || isDev;
        this.db = new DataSource({
            name: "config",
            type: "better-sqlite3",
            database: dbPath,
            entities: [Config, Alert, Device, Queue, Webhook, Contact, ContactAddress, ScheduledMessage],
            migrations: [ContactTables1654432080899, ScheduledMessageTable1665083072000],
            migrationsRun: !shouldSync,
            migrationsTableName: "migrations",
            synchronize: shouldSync
        });

        this.db = await this.db.initialize();

        // Load default config items
        await this.loadConfig();
        await this.setupDefaults();
        return this.db;
    }

    /**
     * Get the device repo
     */
    devices() {
        return this.db.getRepository(Device);
    }

    /**
     * Get the alert repo
     */
    alerts() {
        return this.db.getRepository(Alert);
    }

    /**
     * Get the device repo
     */
    queue() {
        return this.db.getRepository(Queue);
    }

    /**
     * Get the device repo
     */
    configs() {
        return this.db.getRepository(Config);
    }

    /**
     * Get the webhooks repo
     */
    webhooks() {
        return this.db.getRepository(Webhook);
    }

    /**
     * Get the contacts repo
     */
    contacts() {
        return this.db.getRepository(Contact);
    }

    /**
     * Get the contact addresses repo
     */
    contactAddresses() {
        return this.db.getRepository(ContactAddress);
    }

    /**
     * Get the scheduled messages repo
     */
    scheduledMessages() {
        return this.db.getRepository(ScheduledMessage);
    }

    private async loadConfig() {
        const items: Config[] = await this.configs().find();
        for (const i of items) this.config[i.name] = ServerRepository.convertFromDbValue(i.value);
    }

    /**
     * Checks if the config has an item
     *
     * @param name The name of the item to check for
     */
    hasConfig(name: string): boolean {
        return Object.keys(this.config).includes(name);
    }

    /**
     * Retrieves a config item from the cache
     *
     * @param name The name of the config item
     */
    getConfig(name: string): Date | string | boolean | number {
        if (!Object.keys(this.config).includes(name)) return null;
        return ServerRepository.convertFromDbValue(this.config[name] as any);
    }

    /**
     * Sets a config item in the database
     *
     * @param name The name of the config item
     * @param value The value for the config item
     */
    async setConfig(name: string, value: Date | string | boolean | number, persist = true): Promise<void> {
        const orig = { ...this.config };
        const saniVal = ServerRepository.convertToDbValue(value);

        // Either change or create the new Config object
        if (persist) {
            const item = await this.configs().findOneBy({ name });
            if (item) {
                await this.configs().update(item, { value: saniVal });
            } else {
                const cfg = this.configs().create({ name, value: saniVal });
                await this.configs().save(cfg);
            }
        }

        this.config[name] = ServerRepository.convertFromDbValue(saniVal);
        super.emit("config-update", { prevConfig: orig, nextConfig: this.config });
    }

    async purgeOldDevices() {
        // Get devices that have a null last_active or older than 31 days
        const sevenDaysAgo = new Date().getTime() - 86400 * 1000 * 31;  // Now - 31 days
        const devicesToDelete = (await this.devices().find()).filter(
            (item: Device) => !item.last_active || (item.last_active && item.last_active <= sevenDaysAgo)
        );

        // Delete the devices
        if (isNotEmpty(devicesToDelete)) {
            Server().log(
                `Automatically purging ${devicesToDelete.length} devices from your server (inactive for 31 days)`);
            for (const item of devicesToDelete) {
                const dateStr = item.last_active ? new Date(item.last_active).toLocaleDateString() : "N/A";
                Server().log(`    -> Device: ${item.name} (Last Active: ${dateStr})`);
                await this.devices().delete({ name: item.name, identifier: item.identifier });
            }
        }
    }

    public async getWebhooks({
        url = null,
        id = null
    }: {
        url?: string | null;
        id?: number | null;
    } = {}): Promise<Array<Webhook>> {
        const repo = this.webhooks();
        if (id) return [await repo.findOneBy({ id })];
        if (url) return [await repo.findOneBy({ url })];
        return await repo.find();
    }

    public async getContacts(withAvatars = false): Promise<Array<Contact>> {
        const repo = this.contacts();
        const fields: (keyof Contact)[] = ["firstName", "lastName", "displayName", "id"];
        if (withAvatars) {
            fields.push("avatar");
        }

        return await repo.find({ select: fields, relations: ["addresses"] });
    }

    public async addWebhook(url: string, events: Array<{ label: string; value: string }>): Promise<Webhook> {
        const repo = this.webhooks();
        const item = await repo.findOneBy({ url });

        // If the webhook exists, don't re-add it, just return it
        if (item) return item;

        const webhook = repo.create({ url, events: JSON.stringify(events.map(e => e.value)) });
        return await repo.save(webhook);
    }

    public async updateWebhook({
        id,
        url = null,
        events = null
    }: {
        id: number;
        url: string;
        events: Array<{ label: string; value: string }>;
    }): Promise<Webhook> {
        const repo = this.webhooks();
        const item = await repo.findOneBy({ id });
        if (!item) throw new Error("Failed to update webhook! Existing webhook does not exist!");

        if (url) item.url = url;
        if (events) item.events = JSON.stringify(events.map(e => e.value));

        await repo.update(id, item);
        return item;
    }

    public async deleteWebhook({ url = null, id = null }: { url?: string | null; id?: number | null }): Promise<void> {
        if (!url && !id) throw new Error("Failed to delete webhook! No URL or ID provided!");
        const repo = this.webhooks();
        const item = url ? await repo.findOneBy({ url }) : await repo.findOneBy({ id });
        if (!item) return;
        await repo.delete(item.id);
    }

    public async hasQueuedMessage(tempGuid: string): Promise<boolean> {
        const repo = this.queue();

        // Get all queued items
        let entries = await repo.find();
        if (isEmpty(entries)) return false;

        // Check if any have a matching tempGUID
        entries = entries.filter(item => item.tempGuid === tempGuid || item.text.startsWith(tempGuid));

        // Return if there are tempGUID matches
        return isNotEmpty(entries);
    }

    /**
     * This sets any default database values, if the database
     * has not already been initialized
     */
    private async setupDefaults(): Promise<void> {
        try {
            for (const key of Object.keys(DEFAULT_DB_ITEMS)) {
                const item = await this.hasConfig(key);
                if (!item) await this.setConfig(key, DEFAULT_DB_ITEMS[key]());
            }
        } catch (ex: any) {
            Server().log(`Failed to setup default configurations! ${ex.message}`, "error");
        }
    }

    /**
     * Converts a generic string value from the database
     * to its' corresponding correct typed value
     *
     * @param input The value straight from the database
     */
    private static convertFromDbValue(input: string): any {
        if (input === "1" || input === "0") return Boolean(Number(input));
        if (/^-{0,1}\d+$/.test(input)) return Number(input);
        return input;
    }

    /**
     * Converts a typed database value input to a string.
     *
     * @param input The typed database value
     */
    private static convertToDbValue(input: any): string {
        if (typeof input === "boolean") return input ? "1" : "0";
        if (input instanceof Date) return String(input.getTime());
        return String(input);
    }
}
