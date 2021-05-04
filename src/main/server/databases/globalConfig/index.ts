import { app } from "electron";
import { EventEmitter } from "events";
import { createConnection, Connection } from "typeorm";

import { Server } from "@server/index";
import { Config } from "./entity";
import { IConfig, ConfigTypes } from "./types";
import { ConfigOptions } from "./defaults";

export class GlobalConfig extends EventEmitter {
    dbName = "global";

    dbConn: Connection = null;

    config: IConfig;

    constructor() {
        super();

        this.dbConn = null;
        this.config = {};
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
            entities: [Config],
            logging: false,
            migrationsTableName: "migrations",
            migrationsRun: true,
            migrations: []
        });

        try {
            const repo = this.dbConn.getRepository(Config);
            await repo.count();
        } catch (ex) {
            // If this fails, we need to synchronize
            this.dbConn.synchronize();
        }

        // Load default config items
        await this.loadConfig();
        await this.setupDefaults();
        return this.dbConn;
    }

    /**
     * Get the configs repo
     */
    configs() {
        return this.dbConn.getRepository(Config);
    }

    private async loadConfig() {
        const items: Config[] = await this.configs().find();
        for (const i of items) this.config[i.name] = GlobalConfig.convertFromDbValue(i.value, i.type as ConfigTypes);
    }

    /**
     * Checks if the config has an item
     *
     * @param name The name of the item to check for
     */
    contains(name: string): boolean {
        return Object.keys(this.config).includes(name);
    }

    /**
     * Retrieves a config item from the cache
     *
     * @param name The name of the config item
     */
    get(name: string): Date | string | boolean | number {
        if (!Object.keys(this.config).includes(name)) return null;
        const optType = ConfigOptions[name].type;
        return GlobalConfig.convertFromDbValue(this.config[name] as any, optType);
    }

    /**
     * Sets a config item in the database
     *
     * @param name The name of the config item
     * @param value The value for the config item
     */
    async set(name: string, value: Date | string | boolean | number): Promise<void> {
        const orig = { ...this.config };
        const saniVal = GlobalConfig.convertToDbValue(value);
        const item = await this.configs().findOne({ name });

        // Either change or create the new Config object
        if (item) {
            await this.configs().update(item, { value: saniVal });
        } else {
            throw new Error(`Configuration item "${name}" does not exist`);
        }

        this.config[name] = GlobalConfig.convertFromDbValue(saniVal, item.type as ConfigTypes);
        this.emit("config-update", { prevConfig: orig, nextConfig: this.config });
    }

    /**
     * This sets any default database values, if the database
     * has not already been initialized
     */
    private async setupDefaults(): Promise<void> {
        try {
            for (const key of Object.keys(ConfigOptions)) {
                const item = await this.contains(key);
                const definition = ConfigOptions[key];
                if (!item) {
                    const cfg = this.configs().create({
                        name: definition.name,
                        type: definition.type,
                        value: definition.default()
                    });

                    await this.configs().save(cfg);
                }
            }
        } catch (ex) {
            Server().logger.error(`Failed to setup default configurations! ${ex.message}`);
        }
    }

    /**
     * Converts a generic string value from the database
     * to its' corresponding correct typed value
     *
     * @param input The value straight from the database
     * @param type The type straight from the database
     */
    private static convertFromDbValue(input: string, type: ConfigTypes): any {
        if (type === ConfigTypes.BOOLEAN) return input === "1";
        if (type === ConfigTypes.DATE) return new Date(input);
        if (type === ConfigTypes.JSON) return JSON.parse(input);
        if (type === ConfigTypes.NUMBER) return Number.parseInt(input, 10);
        return input;
    }

    /**
     * Converts a typed database value input to a string.
     *
     * @param input The typed database value
     */
    private static convertToDbValue(input: any): string {
        if (input instanceof Boolean) return input ? "1" : "0";
        if (input instanceof Date) return input.getTime().toString();

        const objectConstructor = {}.constructor;
        const arrayConstructor = [].constructor;
        if (input.constructor === objectConstructor || input.constructor === arrayConstructor)
            return JSON.stringify(input);

        if (input instanceof Number) return input.toString();
        return input;
    }
}
