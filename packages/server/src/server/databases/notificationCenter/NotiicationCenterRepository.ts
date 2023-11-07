import fs from "fs";
import { Brackets, DataSource } from "typeorm";
import { Record } from "./entity/Record";
import { App } from "./entity/App";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";
import { DBWhereItem } from "../imessage/types";
import { isNotEmpty } from "@server/helpers/utils";

let repo: NotificationCenterDatabase = null;
export const NotificationCenterDB = () => {
    if (repo) return repo;
    repo = new NotificationCenterDatabase();
    return repo;
};

/**
 * A repository class to facilitate pulling information from the iMessage database
 */
class NotificationCenterDatabase {
    db: DataSource = null;
    
    error: any = null;

    initPromise: Promise<DataSource> = null;

    constructor() {
        this.db = null;
        this.error = null;

        this.initPromise = this.initialize();
        this.initPromise.catch(err => {
            this.error = err;
            Server().log(`Failed to initialize the NotificationCenter database! Error: ${err}`, "error");
        });
    }

    async getDbPath(): Promise<string> {
        const basePath = await FileSystem.getUserConfDir();
        return `${basePath}com.apple.notificationcenter/db2/db`;
    }

    async dbExists(): Promise<boolean> {
        const path = await this.getDbPath();
        return fs.existsSync(path);
    }

    /**
     * Creates a connection to the iMessage database
     */
    async initialize() {
        // Reset the error flag
        this.error = null;

        // Check if the DB path exists
        const dbPath = await this.getDbPath();
        if (!this.dbExists()) {
            throw new Error("NotificationCenter database does not exist!");
        }

        if (this.db) {
            if (!this.db.isInitialized) {
                this.db = await this.db.initialize();
            }

            return this.db;
        }
    
        this.db = new DataSource({
            name: "NotificationCenter",
            type: "better-sqlite3",
            database: dbPath,
            entities: [Record, App]
        });

        this.db = await this.db.initialize();
        return this.db;
    }

    async getRecords({
            limit = 100,
            offset = 0,
            sort = "DESC",
            sortField = "deliveredDate",
            withApp = true,
            where = []
        }: {
            limit?: number;
            offset?: number;
            sort?: "ASC" | "DESC";
            sortField?: string;
            withApp?: boolean;
            where?: DBWhereItem[];
        } = {}
    ): Promise<[Record[], number]> {
        if (this.initPromise) await this.initPromise;
        if (this.error) throw this.error;
        if (!this.db) throw new Error("Database is not initialized!");
        const repo = this.db.getRepository(Record);
        const query = repo.createQueryBuilder("record");

        if (withApp) {
            query.leftJoinAndSelect("record.app", "app");
        }

        // Add any custom WHERE clauses
        if (isNotEmpty(where)) {
            query.andWhere(
                new Brackets(qb => {
                    for (const item of where) {
                        qb.andWhere(item.statement, item.args);
                    }
                })
            );
        }

        query
            .orderBy(`record.${sortField}`, sort)
            .take(limit)
            .skip(offset);

        return await query.getManyAndCount();
    }
}
