import { v4 as UUID } from "uuid";
import { EventEmitter } from "events";
import { createConnection, Connection, FindConditions } from "typeorm";

import { IConfig } from "./types";
import type DefaultApiPlugin from "../index";
import { Token } from "./entity";

export class ApiDatabase extends EventEmitter {
    dbName = "storage";

    plugin: DefaultApiPlugin;

    dbConn: Connection = null;

    config: IConfig;

    constructor(plugin: DefaultApiPlugin) {
        super();

        this.plugin = plugin;
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
            database: `${this.plugin.path}/${this.dbName}.db`,
            entities: [Token],
            logging: false,
            migrationsTableName: "migrations",
            migrationsRun: true,
            migrations: []
        });

        try {
            const repo = this.dbConn.getRepository(Token);
            await repo.count();
        } catch (ex) {
            // If this fails, we need to synchronize
            this.dbConn.synchronize();
        }

        return this.dbConn;
    }

    /**
     * Get the configs repo
     */
    tokens() {
        return this.dbConn.getRepository(Token);
    }

    async getToken(token: string, type = "accessToken") {
        let params: FindConditions<Token> = { accessToken: token };
        if (type === "refreshToken") {
            params = { refreshToken: token };
        }

        return this.tokens().findOne(params);
    }

    async generateToken(name?: string) {
        const token = new Token();
        if (name) token.name = name;
        token.accessToken = UUID();
        token.refreshToken = UUID();

        // Save the DB entry for the tokens
        return this.tokens().save(token);
    }
}
