/* eslint-disable no-param-reassign */
import fs from "fs";
import { DataSource } from "typeorm";
import { FindMyReference } from "./entity/FindMyReference";

/**
 * A repository class to facilitate pulling information from the iMessage database
 */
export class FindMyRepository {
    db: DataSource = null;

    dbPath = `${process.env.HOME}/Library/Caches/com.apple.icloud.fmfd/Cache.db`;

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
            name: "FindMy",
            type: "better-sqlite3",
            database: this.dbPath,
            entities: [FindMyReference]
        });

        this.db = await this.db.initialize();
        return this.db;
    }

    async getLatestCacheReference() {
        // Get messages with sender and the chat it's from
        const query = await this.db.getRepository(FindMyReference)
            .createQueryBuilder()
            .select()
            .where("isDataOnFS = :isDataOnFS", { isDataOnFS: true })
            .orderBy("entry_ID", "DESC");
        return query.getOne();
    }
}
