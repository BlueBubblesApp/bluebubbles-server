import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { MessageInterface } from "@server/api/v1/interfaces/messageInterface";
import { SendMessageParams } from "@server/api/v1/types";
import { FindOneOptions } from "typeorm";

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

    async saveScheduledMessage(scheduledMessage: ScheduledMessage) {
        Server().emitToUI("scheduled-message-update", scheduledMessage);
        await Server().repo.scheduledMessages().save(scheduledMessage);
    }

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
        Server().log(`Creating new scheduled message: ${scheduledMessage.toString()}`);

        const repo = Server().repo.scheduledMessages();
        const newScheduledMessage = repo.create(scheduledMessage);
        await this.saveScheduledMessage(newScheduledMessage);
        await this.scheduleMessage(newScheduledMessage);
        return newScheduledMessage;
    }

    async deleteScheduledMessage(id: number): Promise<void> {
        const repo = Server().repo.scheduledMessages();
        const findOptions: FindOneOptions<ScheduledMessage> = { where: { id } } as FindOneOptions<ScheduledMessage>;
        const scheduledMessage = await repo.findOne(findOptions);
        if (scheduledMessage) {
            Server().log(`Deleting scheduled message: ${scheduledMessage.toString()}`);
            await repo.remove(scheduledMessage);
        } else {
            throw new Error("Scheduled message not found");
        }

        if (Object.keys(this.timers).includes(String(id))) {
            clearTimeout(this.timers[String(id)]);
            delete this.timers[String(id)];
        }
    }

    async deleteScheduledMessages(): Promise<void> {
        const repo = Server().repo.scheduledMessages();
        const scheduledMessages = await repo.find();
        const ids = scheduledMessages.map(scheduledMessage => scheduledMessage.id);
        await repo.clear();

        for (const id of ids) {
            if (Object.keys(this.timers).includes(String(id))) {
                clearTimeout(this.timers[String(id)]);
                delete this.timers[String(id)];
            }
        }
    }

    async scheduleMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        // If it's in progress, mark it as failed
        if (scheduledMessage.status === ScheduledMessageStatus.IN_PROGRESS) {
            scheduledMessage.status = ScheduledMessageStatus.ERROR;
            scheduledMessage.error = "Server was restarted while the scheduled message was in progress.";
            await this.saveScheduledMessage(scheduledMessage);
            return;
        }

        if (scheduledMessage.status !== ScheduledMessageStatus.PENDING) return;

        const now = new Date();
        const diff = scheduledMessage.scheduledFor.getTime() - now.getTime();

        // If the schedule has passed, do not schedule it.
        if (diff <= 0) {
            Server().log(`Expiring: ${scheduledMessage.toString()}`);
            Server().log(`Scheduled message was ${diff} ms late`, "debug");
            await this.handleExpiredMessage(scheduledMessage);
        } else {
            Server().log(`Scheduling (in ${diff} ms): ${scheduledMessage.toString()}`);
            this.timers[String(scheduledMessage.id)] = setTimeout(() => {
                this.sendScheduledMessage(scheduledMessage);
            }, diff);
        }
    }

    async handleExpiredMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        // Set the status to error, and remove the schedule for it
        scheduledMessage.status = ScheduledMessageStatus.ERROR;
        scheduledMessage.error = "Message expired before it could be sent. Or the server was not online at the time.";

        // Reschedule the message
        await this.tryReschedule(scheduledMessage);

        // Save the message
        await this.saveScheduledMessage(scheduledMessage);
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
        if (nextTs === 0) {
            throw new Error("Invalid schedule! Next schedule would have been 0 ms in the future.");
        }

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
        Server().log(`Sending: ${scheduledMessage.toString()}`);

        // Set the status to in-progress
        scheduledMessage.status = ScheduledMessageStatus.IN_PROGRESS;
        this.saveScheduledMessage(scheduledMessage);

        // Send the message
        try {
            if (scheduledMessage.type === ScheduledMessageType.SEND_MESSAGE) {
                await MessageInterface.sendMessageSync({ ...(scheduledMessage.payload as SendMessageParams) });
            }

            scheduledMessage.sentAt = new Date();
        } catch (ex: any) {
            Server().log(`Failed to send scheduled message: ${ex?.message ?? String(ex)}`);
            scheduledMessage.status = ScheduledMessageStatus.ERROR;
            scheduledMessage.error = String(ex);
        } finally {
            if (scheduledMessage.status !== ScheduledMessageStatus.ERROR) {
                scheduledMessage.status = ScheduledMessageStatus.COMPLETE;
            }
        }

        // Reschedule the message
        await this.tryReschedule(scheduledMessage);

        // Save the message
        await this.saveScheduledMessage(scheduledMessage);
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
