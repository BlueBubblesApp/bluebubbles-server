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
