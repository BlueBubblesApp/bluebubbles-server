import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { isNotEmpty } from "@server/helpers/utils";
import { ScheduledMessageScheduleType, ScheduledMessageType } from "@server/services/scheduledMessagesService";
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

    static async getScheduledMessage(id: number): Promise<ScheduledMessage> {
        const repo = Server().repo.scheduledMessages();
        const res = await repo.findBy({ id });
        return isNotEmpty(res) ? res[0] : null;
    }
}
