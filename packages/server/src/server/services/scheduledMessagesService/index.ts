import * as process from "process";
import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { MessageInterface } from "@server/api/v1/interfaces/messageInterface";
import { SendMessageParams } from "@server/api/v1/types";

export enum ScheduledMessageStatus {
    PENDING = "pending",
    IN_PROGRESS = "in-progress",
    COMPLETE = "complete",
    ERROR = "error"
}

export enum ScheduledMessageType {
    SEND_MESSAGE = "send-message"
}

export enum ScheduledMessageScheduleType {
    ONCE = "once",
    RECURRING = "recurring"
}

export enum ScheduledMessageScheduleRecurringType {
    HOURLY = "hourly",
    DAILY = "daily",
    WEEKLY = "weekly",
    MONTHLY = "monthly",
    YEARLY = "yearly"
}

/**
 * Service that manages scheduled messages
 */
export class ScheduledMessagesService {
    private timers: Record<string, NodeJS.Timeout> = {};

    async loadAndSchedule() {
        const schedules = await this.getScheduledMessages();
        for (const schedule of schedules) {
            await this.scheduleMessage(schedule);
        }
    }

    async getScheduledMessages() {
        const repo = Server().repo.scheduledMessages();
        return await repo.find();
    }

    async createScheduledMessage(scheduledMessage: ScheduledMessage): Promise<ScheduledMessage> {
        const repo = Server().repo.scheduledMessages();
        const newScheduledMessage = repo.create(scheduledMessage);
        await repo.save(newScheduledMessage);
        await this.scheduleMessage(newScheduledMessage);
        return newScheduledMessage;
    }

    async deleteScheduledMessage(id: number): Promise<void> {
        const repo = Server().repo.scheduledMessages();
        const scheduledMessage = await repo.findBy({ id });
        if (scheduledMessage) {
            await repo.remove(scheduledMessage);
        }

        if (Object.keys(this.timers).includes(String(id))) {
            clearTimeout(this.timers[String(id)]);
            delete this.timers[String(id)];
        }
    }

    async scheduleMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        const now = new Date();
        const diff = scheduledMessage.scheduledFor.getTime() - now.getTime();

        // If the schedule has passed, do not schedule it.
        if (diff <= 0) {
            await this.handleExpiredMessag(scheduledMessage);
        } else {
            this.timers[String(scheduledMessage.id)] = setTimeout(() => {
                this.sendScheduledMessage(scheduledMessage);
            }, diff);
        }
    }

    async handleExpiredMessag(scheduledMessage: ScheduledMessage): Promise<void> {
        // Set the status to error, and remove the schedule for it
        scheduledMessage.status = ScheduledMessageStatus.ERROR;
        scheduledMessage.error = "Message expired before it could be sent. Or the server was not online at the time.";
        scheduledMessage.scheduledFor = null;

        // Reschedule the message
        await this.tryReschedule(scheduledMessage);

        // Save the message
        await Server().repo.scheduledMessages().save(scheduledMessage);
    }

    async tryReschedule(scheduledMessage: ScheduledMessage): Promise<void> {
        // Remove the timer from the timers object
        if (Object.keys(this.timers).includes(String(scheduledMessage.id))) {
            clearTimeout(this.timers[String(scheduledMessage.id)]);
            delete this.timers[String(scheduledMessage.id)];
        }

        // If it's a recurring message, schedule it again
        const isRecurring = scheduledMessage.schedule.type === ScheduledMessageScheduleType.RECURRING;
        if (isRecurring) {
            scheduledMessage.status = ScheduledMessageStatus.PENDING;
            scheduledMessage.scheduledFor = this.getNextRecurringDate(scheduledMessage.schedule);
            await this.scheduleMessage(scheduledMessage);
        }
    }

    getNextRecurringDate(schedule: NodeJS.Dict<any>): Date {
        const nextTs = this.getMillisecondsForSchedule(schedule);
        const now = new Date().getTime();
        return new Date(now + nextTs);
    }

    getMillisecondsForSchedule(schedule: NodeJS.Dict<any>) {
        if (schedule.type !== ScheduledMessageScheduleType.RECURRING) {
            return null;
        }

        const intervalType = schedule.intervalType;
        const interval = schedule.interval;
        switch (intervalType) {
            case ScheduledMessageScheduleRecurringType.HOURLY:
                return interval * 60 * 60 * 1000;
            case ScheduledMessageScheduleRecurringType.DAILY:
                return interval * 24 * 60 * 60 * 1000;
            case ScheduledMessageScheduleRecurringType.WEEKLY:
                return interval * 7 * 24 * 60 * 60 * 1000;
            case ScheduledMessageScheduleRecurringType.MONTHLY:
                return interval * 30 * 24 * 60 * 60 * 1000;
            case ScheduledMessageScheduleRecurringType.YEARLY:
                return interval * 365 * 24 * 60 * 60 * 1000;
            default:
                return null;
        }
    }

    async sendScheduledMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        // Set the status to in-progress
        scheduledMessage.status = ScheduledMessageStatus.IN_PROGRESS;
        Server().repo.scheduledMessages().save(scheduledMessage);

        // Send the message
        try {
            if (scheduledMessage.type === ScheduledMessageType.SEND_MESSAGE) {
                await MessageInterface.sendMessageSync({ ...(scheduledMessage.payload as SendMessageParams) });
            }

            scheduledMessage.sentAt = new Date();
        } catch (ex) {
            scheduledMessage.status = ScheduledMessageStatus.ERROR;
            scheduledMessage.error = String(ex);
        } finally {
            if (scheduledMessage.status !== ScheduledMessageStatus.ERROR) {
                scheduledMessage.status = ScheduledMessageStatus.COMPLETE;
            }

            scheduledMessage.scheduledFor = null;
        }

        // Reschedule the message
        await this.tryReschedule(scheduledMessage);

        // Save the message
        await Server().repo.scheduledMessages().save(scheduledMessage);
    }

    start() {
        this.loadAndSchedule();
    }

    /**
     * Stops all the timers
     */
    stop() {
        for (const timer of Object.values(this.timers)) {
            clearTimeout(timer);
        }

        this.timers = {};
    }
}
