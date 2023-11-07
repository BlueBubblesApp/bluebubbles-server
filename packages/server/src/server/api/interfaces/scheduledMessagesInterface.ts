import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { ScheduledMessageScheduleType, ScheduledMessageType } from "@server/services/scheduledMessagesService";
import { FindOneOptions } from "typeorm";
import { SendMessageParams } from "../types";

/**
 * An interface for the scheduled messages API.
 * Any piece of code interacting with the scheduled
 * messages API should use this interface instead
 * of directly calling the DB or the service.
 */
export class ScheduledMessagesInterface {
    static validateSchedule(
        scheduledFor: Date,
        schedule: {
            type: ScheduledMessageScheduleType;
            intervalType?: string;
            interval?: number;
        }
    ) {
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
    }
    /**
     * Gets all scheduled messages from the DB.
     *
     * @returns The scheduled messages.
     */
    static async getScheduledMessages(): Promise<ScheduledMessage[]> {
        return await Server().scheduledMessages.getScheduledMessages();
    }

    /**
     * Creates a new scheduled message.
     *
     * @param type The type of the scheduled message.
     * @param payload The payload to invoke the action type.
     * @param scheduledFor The date the message should be sent.
     * @param schedule The schedule configuration.
     * @returns The newly created scheduled message.
     */
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
        ScheduledMessagesInterface.validateSchedule(scheduledFor, schedule);

        const msg = new ScheduledMessage();
        msg.type = type;
        msg.payload = payload;
        msg.scheduledFor = scheduledFor;
        msg.schedule = schedule;
        msg.status = "pending";
        return await Server().scheduledMessages.createScheduledMessage(msg);
    }

    /**
     * Updates an existing scheduled message.
     *
     * @param type The type of the scheduled message.
     * @param payload The payload to invoke the action type.
     * @param scheduledFor The date the message should be sent.
     * @param schedule The schedule configuration.
     * @returns The newly created scheduled message.
     */
    static async updateScheduledMessage(
        id: number,
        type: ScheduledMessageType,
        payload: SendMessageParams,
        scheduledFor: Date,
        schedule: {
            type: ScheduledMessageScheduleType;
            intervalType?: string;
            interval?: number;
        }
    ): Promise<ScheduledMessage> {
        ScheduledMessagesInterface.validateSchedule(scheduledFor, schedule);

        const msg = new ScheduledMessage();
        msg.type = type;
        msg.payload = payload;
        msg.scheduledFor = scheduledFor;
        msg.schedule = schedule;

        return await Server().scheduledMessages.updateScheduledMessage(id, msg);
    }

    /**
     * Deletes a single scheduled message by ID/
     *
     * @param id The ID of the scheduled message to delete.
     */
    static async deleteScheduledMessage(id: number): Promise<void> {
        return await Server().scheduledMessages.deleteScheduledMessage(id);
    }

    /**
     * Deletes all scheduled messages from the DB.
     */
    static async deleteScheduledMessages(): Promise<void> {
        return await Server().scheduledMessages.deleteScheduledMessages();
    }

    /**
     * Gets a specific scheduled message by ID.
     *
     * @param id The ID of the scheduled message to get.
     * @returns The scheduled message.
     */
    static async getScheduledMessage(id: number): Promise<ScheduledMessage> {
        const repo = Server().repo.scheduledMessages();
        const findOpts: FindOneOptions<ScheduledMessage> = { where: { id } } as FindOneOptions<ScheduledMessage>;
        return await repo.findOne(findOpts);
    }
}
