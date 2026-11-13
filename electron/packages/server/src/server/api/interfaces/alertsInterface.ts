import { Server } from "@server";
import { Alert } from "@server/databases/server/entity/Alert";
import { isEmpty } from "@server/helpers/utils";

import { AlertTypes } from "../types/alertTypes";

/**
 * An interface to interact with server alerts
 */
export class AlertsInterface {
    static async find(limit = 10): Promise<Alert[]> {
        const query = Server().repo.alerts().createQueryBuilder("alert").orderBy("created", "DESC").limit(limit);
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

    static async markAsRead(ids: number[]): Promise<void> {
        if (isEmpty(ids)) return;
    
        // Find the corresponding alert
        const query = Server().repo.alerts().createQueryBuilder()
            .update()
            .set({ isRead: true })
            .where("alert.id IN (:...ids)", { ids });
        await query.execute();

        const alerts = (await AlertsInterface.find(100)).filter(e => !e.isRead);
        Server().setNotificationCount(alerts.length);
        Server().emitToUI("refresh-alerts", null);
    }

    static async delete(id: number): Promise<void> {
        // Find the corresponding alert
        const alert = await Server().repo.alerts().findOneBy({ id });
        if (!alert) return;

        await Server().repo.alerts().remove(alert);
    }
}
