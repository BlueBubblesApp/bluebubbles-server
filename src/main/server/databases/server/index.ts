import { app } from "electron";
import { EventEmitter } from "events";
import { createConnection, Connection } from "typeorm";

import { Server } from "@server/index";
import { Alert, Device, Queue, Plugin } from "./entity";
import { CreatePluginParams, IConfig, ConfigTypes } from "./types";

export class ServerDatabase extends EventEmitter {
    dbName = "server";

    dbConn: Connection = null;

    constructor() {
        super();

        this.dbConn = null;
    }

    async initialize(): Promise<Connection> {
        // If the DB is set, but not connected, try to connect
        if (this.dbConn) {
            if (!this.dbConn.isConnected) await this.dbConn.connect();
            return this.dbConn;
        }

        this.dbConn = await createConnection({
            name: this.dbName,
            type: "better-sqlite3",
            database: `${Server().appPath}/${this.dbName}.db`,
            entities: [Alert, Device, Queue, Plugin],
            logging: false,
            migrationsTableName: "migrations",
            migrationsRun: true,
            migrations: []
        });

        try {
            const repo = this.dbConn.getRepository(Plugin);
            await repo.count();
        } catch (ex) {
            // If this fails, we need to synchronize
            this.dbConn.synchronize();
        }

        return this.dbConn;
    }

    /**
     * Get the device repo
     */
    devices() {
        return this.dbConn.getRepository(Device);
    }

    /**
     * Get the alert repo
     */
    alerts() {
        return this.dbConn.getRepository(Alert);
    }

    /**
     * Get the queue repo
     */
    queue() {
        return this.dbConn.getRepository(Queue);
    }

    /**
     * Get the plugins repo
     */
    plugins() {
        return this.dbConn.getRepository(Plugin);
    }

    async purgeOldDevices() {
        // Get devices that have a null last_active or older than 7 days
        const sevenDaysAgo = new Date().getTime() - 86400 * 1000 * 7; // Now - 7 days
        const devicesToDelete = (await this.devices().find()).filter(
            (item: Device) => !item.last_active || (item.last_active && item.last_active <= sevenDaysAgo)
        );

        // Delete the devices
        if (devicesToDelete.length > 0) {
            Server().logger.debug(`Automatically purging ${devicesToDelete.length} devices from your server`);
            for (const item of devicesToDelete) {
                const dateStr = item.last_active ? new Date(item.last_active).toLocaleDateString() : "N/A";
                Server().logger.debug(`    -> Device: ${item.name} (Last Active: ${dateStr})`);
                await this.devices().delete({ name: item.name, identifier: item.identifier });
            }
        }
    }

    static createPlugin({
        name,
        displayName,
        enabled,
        type,
        description = "",
        version = 1,
        properties = null
    }: CreatePluginParams) {
        const plugin = new Plugin();

        plugin.name = name;
        plugin.displayName = displayName;
        plugin.enabled = enabled;
        plugin.type = type;
        plugin.description = description;
        plugin.version = version;
        plugin.properties = properties;

        return plugin;
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
