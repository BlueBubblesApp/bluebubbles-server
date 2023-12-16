/* eslint-disable no-param-reassign */
import fs from "fs";
import { DataSource } from "typeorm";
import { CallRecord } from "./entity/CallRecord";

/**
 * A repository class to facilitate pulling information from the iMessage database
 */
export class CallHistoryRepository {
    db: DataSource = null;

    dbPath = `${process.env.HOME}/Library/Application Support/CallHistoryDB/CallHistory.storedata`;

    constructor() {
        this.db = null;
    }

    dbExists(): boolean {
        return fs.existsSync(this.dbPath);
    }

    /**
     * Creates a connection to the iMessage database
     */
    async initialize() {
        if (!this.dbExists()) return null;
        if (this.db) {
            if (!this.db.isInitialized) {
                this.db = await this.db.initialize();
            }

            return this.db;
        }
    
        this.db = new DataSource({
            name: "CallHistory",
            type: "better-sqlite3",
            database: this.dbPath,
            entities: [CallRecord]
        });

        this.db = await this.db.initialize();
        return this.db;
    }

    history() {
        return this.db.getRepository(CallRecord);
    }
}
