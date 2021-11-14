import { Server } from "@server/index";
import { Alert } from "@server/databases/server/entity/Alert";

import { AlertTypes } from "./types";

/**
 * This services manages alerts to the server dashboard
 */
export class AlertService {
    static async find(): Promise<Alert[]> {
        const query = Server().repo.alerts().createQueryBuilder("alert").orderBy("created", "DESC").limit(10);
        return query.getMany();
    }

    static async create(type: AlertTypes, message: string, isRead = false): Promise<Alert> {
        if (!type || !message) return null;

        // Create the alert based on parameters
        const alert = new Alert();
        alert.type = type;
        alert.value = message;
        alert.isRead = isRead;

        // Save and emit the alert to the UI
        const saved = await Server().repo.alerts().save(alert);
        if (Server().window) Server().window.webContents.send("new-alert", saved);

        // Save and return the alert
        return saved;
    }

    static async markAsRead(id: number): Promise<Alert> {
        // Find the corresponding alert
        const alert = await Server().repo.alerts().findOne(id);
        if (!alert) throw new Error(`Alert [id: ${id}] does not exist!`);

        // Modify and save the alert
        alert.isRead = true;
        return Server().repo.alerts().manager.save(alert);
    }

    static async delete(id: number): Promise<void> {
        // Find the corresponding alert
        const alert = await Server().repo.alerts().findOne(id);
        if (!alert) return;

        await Server().repo.alerts().remove(alert);
    }
}
