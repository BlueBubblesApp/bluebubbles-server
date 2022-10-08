import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { ScheduledMessageScheduleType, ScheduledMessageType } from "@server/services/scheduledMessagesService";
import { FindOneOptions } from "typeorm";
import { SendMessageParams } from "../types";

export class ScheduledMessagesInterface {
    static async getScheduledMessages(): Promise<ScheduledMessage[]> {
        return await Server().scheduledMessages.getScheduledMessages();
    }

    static async createScheduledMessage(
        type: ScheduledMessageType,
        payload: SendMessageParams,
        scheduledFor: Date,
        schedule: {
            type: ScheduledMessageScheduleType;
            intervalType?: string;
            interval?: number;
        }
    ): Promise<ScheduledMessage> {
        if (schedule.type === "recurring" && !schedule.intervalType) {
            throw new Error("Recurring schedule must have an interval type");
        }

        if (schedule.type === "recurring" && (!schedule.interval || schedule.interval === 0)) {
            throw new Error("Recurring schedule must have an interval > 0");
        }

        if (!scheduledFor) {
            throw new Error("Scheduled For date is required");
        }

        if (scheduledFor.getTime() < new Date().getTime()) {
            throw new Error("Scheduled For date must be in the future");
        }

        const msg = new ScheduledMessage();
        msg.type = type;
        msg.payload = payload;
        msg.scheduledFor = scheduledFor;
        msg.schedule = schedule;
        msg.status = "pending";
        return await Server().scheduledMessages.createScheduledMessage(msg);
    }

    static async deleteScheduledMessage(id: number): Promise<void> {
        return await Server().scheduledMessages.deleteScheduledMessage(id);
    }

    static async deleteScheduledMessages(): Promise<void> {
        return await Server().scheduledMessages.deleteScheduledMessages();
    }

    static async getScheduledMessage(id: number): Promise<ScheduledMessage> {
        const repo = Server().repo.scheduledMessages();
        const findOpts: FindOneOptions<ScheduledMessage> = { where: { id } } as FindOneOptions<ScheduledMessage>;
        return await repo.findOne(findOpts);
    }
}
