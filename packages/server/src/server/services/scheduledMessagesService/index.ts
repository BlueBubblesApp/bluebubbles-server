import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { MessageInterface } from "@server/api/v1/interfaces/messageInterface";
import { SendMessageParams } from "@server/api/v1/types";
import { FindOneOptions } from "typeorm";
import { SCHEDULED_MESSAGE_ERROR } from "@server/events";

/**
 * The possible states of a scheduled message
 */
export enum ScheduledMessageStatus {
    PENDING = "pending",
    IN_PROGRESS = "in-progress",
    COMPLETE = "complete",
    ERROR = "error"
}

/**
 * The possible types of a actions a scheduled message
 * can perform
 */
export enum ScheduledMessageType {
    SEND_MESSAGE = "send-message"
}

/**
 * The possible schedule types for a scheduled message
 */
export enum ScheduledMessageScheduleType {
    ONCE = "once",
    RECURRING = "recurring"
}

/**
 * The possible schedule interval types for a recurring
 * scheduled message
 */
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
    /**
     * A cache of all active timers & scheduled messages.
     */
    private timers: Record<string, NodeJS.Timeout> = {};

    /**
     * Emits a message to any listeners, letting them know
     * that a scheduled message has been updated.
     *
     * @param scheduledMessage A scheduled message that was updated
     */
    notifyUpdate(scheduledMessage?: ScheduledMessage) {
        Server().emitToUI("scheduled-message-update", scheduledMessage ?? null);
    }

    /**
     * Notifies all client of a failed scheduled message.
     *
     * @param scheduledMessage The failed scheduled message
     */
    notifyError(scheduledMessage: ScheduledMessage) {
        Server().emitMessage(SCHEDULED_MESSAGE_ERROR, scheduledMessage, "normal", true);
    }

    /**
     * Saves a scheduled message to the DB, as well
     * as emits a message letting the UI know that
     * the scheduled message has been updated.
     *
     * @param scheduledMessage The scheduled message to save
     */
    async saveScheduledMessage(scheduledMessage: ScheduledMessage) {
        this.notifyUpdate(scheduledMessage);
        await Server().repo.scheduledMessages().save(scheduledMessage);
    }

    /**
     * Loads all scheduled messages from the DB and attempts
     * to schedules them.
     */
    async loadAndSchedule() {
        const schedules = await this.getScheduledMessages();
        for (const schedule of schedules) {
            await this.scheduleMessage(schedule);
        }
    }

    /**
     * Gets the scheduled messages from the DB.
     *
     * @returns All of the scheduled messages
     */
    async getScheduledMessages() {
        const repo = Server().repo.scheduledMessages();
        return await repo.find();
    }

    /**
     * Creates a new scheduled message.
     *
     * @param scheduledMessage The scheduled message to create
     * @returns The created scheduled message
     */
    async createScheduledMessage(scheduledMessage: ScheduledMessage): Promise<ScheduledMessage> {
        Server().log(`Creating new scheduled message: ${scheduledMessage.toString()}`);

        const repo = Server().repo.scheduledMessages();
        const newScheduledMessage = repo.create(scheduledMessage);
        await this.saveScheduledMessage(newScheduledMessage);
        await this.scheduleMessage(newScheduledMessage);
        return newScheduledMessage;
    }

    /**
     * Deletes a scheduled message by its' ID.
     *
     * @param id The ID of the scheduled message to delete
     */
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

        this.removeTimer(id);
        this.notifyUpdate();
    }

    /**
     * Removes a timer from the timers object.
     *
     * @param id The timer to remove (by ID)
     */
    removeTimer(id: number) {
        if (Object.keys(this.timers).includes(String(id))) {
            clearTimeout(this.timers[String(id)]);
            delete this.timers[String(id)];
        }
    }

    /**
     * Deletes all scheduled messages.
     */
    async deleteScheduledMessages(): Promise<void> {
        const repo = Server().repo.scheduledMessages();
        const scheduledMessages = await repo.find();
        const ids = scheduledMessages.map(scheduledMessage => scheduledMessage.id);
        await repo.clear();

        for (const id of ids) {
            this.removeTimer(id);
        }

        this.notifyUpdate();
    }

    /**
     * Attempts to schedule a scheduled message. If the message
     * is in progress, it will be skipped, and attempted to be
     * rescheduled if it's recurring. If the message is already
     * complete, it will be skipped and rescheduled if recurring.
     * If the message's scheduled time is in the past, it will be
     * skipped and attempted to be rescheduled if it's recurring.
     *
     * @param scheduledMessage The scheduled message to schedule.
     */
    async scheduleMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        // If it's in progress, mark it as failed
        if (scheduledMessage.status === ScheduledMessageStatus.IN_PROGRESS) {
            Server().log(`Cancelled: ${scheduledMessage.toString()}`);
            return this.handleInterruptedMessage(scheduledMessage);
        }

        if (scheduledMessage.status === ScheduledMessageStatus.COMPLETE) {
            Server().log(`Already Complete: ${scheduledMessage.toString()}`);
            this.tryReschedule(scheduledMessage);
            return;
        }

        if (scheduledMessage.status === ScheduledMessageStatus.ERROR) {
            Server().log(`Already Errored: ${scheduledMessage.toString()}`);
            this.tryReschedule(scheduledMessage);
            return;
        }

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

    /**
     * Sets the correct error for an expired message and will
     * attempt to reschedule it if it's recurring.
     *
     * @param scheduledMessage The message to expire
     */
    async handleExpiredMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        await this.setScheduledMessageError(
            scheduledMessage,
            "Message expired before it could be sent. Or the server was not online at the time."
        );
    }

    /**
     * Sets the correct error for an interrupted message and will
     * attempt to reschedule it if it's recurring.
     *
     * @param scheduledMessage The message to interrupt
     */
    async handleInterruptedMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        await this.setScheduledMessageError(
            scheduledMessage,
            "Server was restarted while the scheduled message was in progress."
        );
    }

    /**
     * Sets an error for the scheduled message. This will also
     * try to reschedule the message if it's recurring.
     *
     * @param scheduledMessage The scheduled message to set the error for
     * @param error The error to set
     */
    async setScheduledMessageError(scheduledMessage: ScheduledMessage, error: string): Promise<void> {
        // Set the status to error, and remove the schedule for it
        scheduledMessage.status = ScheduledMessageStatus.ERROR;
        scheduledMessage.error = error;

        Server().log(`Scheduled Message Error: ${error}`);

        // Reschedule the message
        await this.tryReschedule(scheduledMessage);

        // Save the message
        await this.saveScheduledMessage(scheduledMessage);
    }

    /**
     * Tries to reschedule a message if it's recurring.
     *
     * @param scheduledMessage The message to try and reschedule
     * @returns True if the message was rescheduled, false otherwise
     */
    async tryReschedule(scheduledMessage: ScheduledMessage, removeTimer = true, recalc = true): Promise<boolean> {
        // Remove the timer from the timers object
        if (removeTimer) {
            this.removeTimer(scheduledMessage.id);
        }

        // If it's a recurring message, schedule it again
        const isRecurring = scheduledMessage.schedule.type === ScheduledMessageScheduleType.RECURRING;
        if (isRecurring) {
            if (recalc) {
                scheduledMessage.scheduledFor = this.getNextRecurringDate(scheduledMessage.schedule);
            }

            Server().log(`Rescheduling: ${scheduledMessage.toString()}`);
            scheduledMessage.status = ScheduledMessageStatus.PENDING;
            await this.scheduleMessage(scheduledMessage);
            return true;
        }

        return false;
    }

    /**
     * Gets the next date for a recurring message.
     *
     * @param schedule The scheduling configruation
     * @returns A future date
     */
    getNextRecurringDate(schedule: NodeJS.Dict<any>): Date {
        const nextTs = this.getMillisecondsForSchedule(schedule);
        if (nextTs === 0) {
            throw new Error("Invalid schedule! Next schedule would have been 0 ms in the future.");
        }

        const now = new Date().getTime();
        return new Date(now + nextTs);
    }

    /**
     * Gets the number of milliseconds until the next schedule.
     *
     * @param schedule The configured schedule
     * @returns The number of milliseconds until the next schedule
     */
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

    /**
     * Sends a scheduled message.
     *
     * @param scheduledMessage The message to send
     */
    async sendScheduledMessage(scheduledMessage: ScheduledMessage): Promise<void> {
        Server().log(`Sending: ${scheduledMessage.toString()}`);

        // Set the status to in-progress
        scheduledMessage.status = ScheduledMessageStatus.IN_PROGRESS;

        // Calculate the next schedule time
        scheduledMessage.scheduledFor = this.getNextRecurringDate(scheduledMessage.schedule);

        // Save the updated information
        await this.saveScheduledMessage(scheduledMessage);

        // Inject the method based on if it's not already provided,
        // or if the private api is enabled on the server & connected.
        if (!scheduledMessage.payload.method) {
            const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
            scheduledMessage.payload.method =
                papiEnabled && !!Server().privateApiHelper.helper ? "private-api" : "apple-script";
        }

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

            this.notifyError(scheduledMessage);
        } finally {
            if (scheduledMessage.status !== ScheduledMessageStatus.ERROR) {
                scheduledMessage.status = ScheduledMessageStatus.COMPLETE;
            }
        }

        // Don't recalculate because we already did it above,
        // before the action was taken.
        await this.tryReschedule(scheduledMessage, true, false);

        // Save the message
        await this.saveScheduledMessage(scheduledMessage);
    }

    /**
     * Starts the scheduled message service.
     */
    start() {
        this.loadAndSchedule();
    }

    /**
     * Stops the scheduled message service & clears all timers
     */
    stop() {
        for (const timer of Object.values(this.timers)) {
            clearTimeout(timer);
        }

        this.timers = {};
    }
}
