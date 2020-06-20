import { BrowserWindow } from "electron";
import { Connection } from "typeorm";
import { Alert } from "@server/entity/Alert";

import { AlertTypes } from "./types";

/**
 * This services manages alerts to the server dashboard
 */
export class AlertService {
    db: Connection;

    window: BrowserWindow;

    constructor(db: Connection, window: BrowserWindow) {
        this.db = db;
        this.window = window;
    }

    async find(): Promise<Alert[]> {
        const repo = this.db.getRepository(Alert);
        const query = repo.createQueryBuilder("alert").orderBy("created", "DESC").limit(10);
        return query.getMany();
    }

    async create(type: AlertTypes, message: string, isRead = false): Promise<Alert> {
        const repo = this.db.getRepository(Alert);
        if (!message) return null;

        // Create the alert based on parameters
        const alert = new Alert();
        alert.type = type;
        alert.value = message;
        alert.isRead = isRead;

        // Save and emit the alert to the UI
        const saved = await repo.manager.save(alert);
        if (this.window) this.window.webContents.send("new-alert", saved);

        // Save and return the alert
        return saved;
    }

    async markAsRead(id: number): Promise<Alert> {
        const repo = this.db.getRepository(Alert);

        // Find the corresponding alert
        const alert = await repo.findOne(id);
        if (!alert) throw new Error(`Alert [id: ${id}] does not exist!`);

        // Modify and save the alert
        alert.isRead = true;
        return repo.manager.save(alert);
    }

    async delete(id: number): Promise<void> {
        const repo = this.db.getRepository(Alert);

        // Find the corresponding alert
        const alert = await repo.findOne(id);
        if (!alert) return;

        await repo.manager.remove(alert);
    }
}
