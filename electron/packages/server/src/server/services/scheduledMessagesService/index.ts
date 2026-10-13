import { Server } from "@server";
import { ScheduledMessage } from "@server/databases/server/entity";
import { MessageInterface } from "@server/api/interfaces/messageInterface";
import { SendMessageParams } from "@server/api/types";
import { FindOneOptions } from "typeorm";
import {
    SCHEDULED_MESSAGE_CREATED,
    SCHEDULED_MESSAGE_DELETED,
    SCHEDULED_MESSAGE_ERROR,
    SCHEDULED_MESSAGE_SENT,
    SCHEDULED_MESSAGE_UPDATED
} from "@server/events";
import { Loggable } from "@server/lib/logging/Loggable";
import { safeTimeout } from "@server/utils/TimeUtils";

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
export class ScheduledMessagesService extends Loggable {
    tag = "ScheduledMessagesService";

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
    notifyUpdateUi(scheduledMessage?: ScheduledMessage) {
        Server().emitToUI("scheduled-message-update", scheduledMessage ?? null);
    }

    /**
     * Emits a message to any listeners, letting them know
     * that a scheduled message has been updated.
     *
     * @param scheduledMessage A scheduled message that was updated
     */
    notifyUpdate(scheduledMessage?: ScheduledMessage) {
        Server().emitMessage(SCHEDULED_MESSAGE_UPDATED, scheduledMessage, "normal");
    }

    /**
     * Notifies all client of a created scheduled message.
     *
     * @param scheduledMessage The failed scheduled message
     */
    notifyCreated(scheduledMessage: ScheduledMessage) {
        Server().emitMessage(SCHEDULED_MESSAGE_CREATED, scheduledMessage, "normal");
    }

    /**
     * Notifies all client of a failed scheduled message.
     *
     * @param scheduledMessage The failed scheduled message
     */
    notifyError(scheduledMessage: ScheduledMessage) {
        Server().emitMessage(SCHEDULED_MESSAGE_ERROR, scheduledMessage, "normal");
    }

    /**
     * Notifies all client of a sent scheduled message.
     *
     * @param scheduledMessage The sent scheduled message
     */
    notifySuccess(scheduledMessage: ScheduledMessage) {
        Server().emitMessage(SCHEDULED_MESSAGE_SENT, scheduledMessage, "normal");
    }

    /**
     * Notifies all client of a deleted scheduled message.
     *
     * @param scheduledMessage The deleted scheduled message
     */
    notifyDeleted(scheduledMessages: ScheduledMessage[]) {
        Server().emitMessage(SCHEDULED_MESSAGE_DELETED, scheduledMessages, "normal");
    }

    /**
     * Saves a scheduled message to the DB, as well
     * as emits a message letting the UI know that
     * the scheduled message has been updated.
     *
     * @param scheduledMessage The scheduled message to save
     */
    async saveScheduledMessage(scheduledMessage: ScheduledMessage) {
        await Server().repo.scheduledMessages().save(scheduledMessage);
        this.notifyUpdateUi(scheduledMessage);
        this.notifyCreated(scheduledMessage);
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
        this.log.info(`Creating new scheduled message: ${scheduledMessage.toString()}`);

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
     * @param scheduledMessage The new scheduled message information
     */
    async updateScheduledMessage(id: number, scheduledMessage: ScheduledMessage): Promise<ScheduledMessage> {
        const repo = Server().repo.scheduledMessages();
        const findOptions: FindOneOptions<ScheduledMessage> = { where: { id } } as FindOneOptions<ScheduledMessage>;
        const existingMessage = await repo.findOne(findOptions);
        if (!existingMessage) {
            throw new Error("Scheduled message not found");
        }

        this.log.info(`Updating scheduled message: ${existingMessage.toString()}`);
        const updateRes = await repo.update(id, scheduledMessage);
        scheduledMessage.id = existingMessage.id;

        if (updateRes.affected === 1) {
            this.removeTimer(id);
            await this.scheduleMessage(scheduledMessage);
            this.notifyUpdateUi();
            this.notifyUpdate(scheduledMessage);
        }

        return scheduledMessage;
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
            this.log.info(`Deleting scheduled message: ${scheduledMessage.toString()}`);
            await repo.remove(scheduledMessage);
        } else {
            throw new Error("Scheduled message not found");
        }

        this.removeTimer(id);
        this.notifyUpdate();
        this.notifyDeleted([scheduledMessage]);
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

        this.notifyUpdateUi();
        this.notifyDeleted(scheduledMessages);
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
            this.log.info(`Cancelled: ${scheduledMessage.toString()}`);
            return this.handleInterruptedMessage(scheduledMessage);
        }

        if (scheduledMessage.status === ScheduledMessageStatus.COMPLETE) {
            this.tryReschedule(scheduledMessage);
            return;
        }

        if (scheduledMessage.status === ScheduledMessageStatus.ERROR) {
            this.tryReschedule(scheduledMessage);
            return;
        }

        const now = new Date();
        const diff = scheduledMessage.scheduledFor.getTime() - now.getTime();

        // If the schedule has passed, do not schedule it.
        if (diff <= 0) {
            this.log.info(`Expiring: ${scheduledMessage.toString()}`);
            this.log.debug(`Scheduled message was ${diff} ms late`);
            await this.handleExpiredMessage(scheduledMessage);
        } else {
            this.log.info(`Scheduling (in ${diff} ms): ${scheduledMessage.toString()}`);
            this.timers[String(scheduledMessage.id)] = safeTimeout(() => {
                this.sendScheduledMessage(scheduledMessage);
            }, diff, (newTimeout) => {
                clearTimeout(this.timers[String(scheduledMessage.id)]);
                this.timers[String(scheduledMessage.id)] = newTimeout;
            });
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

        this.log.info(`Scheduled Message Error: ${error}`);

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
                scheduledMessage.scheduledFor = this.getNextRecurringDate(scheduledMessage);
            }

            this.log.info(`Rescheduling: ${scheduledMessage.toString()}`);
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
    getNextRecurringDate(scheduledMessage: ScheduledMessage): Date {
        if (scheduledMessage.schedule.type !== ScheduledMessageScheduleType.RECURRING) {
            throw new Error('Schedule must be of type "recurring" to get the next date!');
        }

        let nowTime = new Date().getTime();
        const previousTime = scheduledMessage.scheduledFor.getTime();
        const nextTs = this.getMillisecondsForSchedule(scheduledMessage.schedule);
        if (nextTs === 0) {
            throw new Error("Invalid schedule! Next schedule would have been 0 ms in the future.");
        }

        // Calculate when the next time should be.
        // Basically, add the schedule'd time to the previous scheduled time
        // until it's in the future.
        let startTime = previousTime + nextTs;
        while (startTime < nowTime) {
            startTime += nextTs;
            nowTime = new Date().getTime();
        }

        return new Date(startTime);
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
        this.log.info(`Sending: ${scheduledMessage.toString()}`);

        // Set the status to in-progress
        scheduledMessage.status = ScheduledMessageStatus.IN_PROGRESS;

        // Calculate the next schedule time (for recurring only)
        if (scheduledMessage.schedule.type === ScheduledMessageScheduleType.RECURRING) {
            scheduledMessage.scheduledFor = this.getNextRecurringDate(scheduledMessage);
        }

        // Save the updated information
        await this.saveScheduledMessage(scheduledMessage);

        // Inject the method based on if it's not already provided,
        // or if the private api is enabled on the server & connected.
        if (!scheduledMessage.payload.method) {
            const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
            scheduledMessage.payload.method =
                papiEnabled && !!Server().privateApi.helper ? "private-api" : "apple-script";
        }

        // Send the message
        try {
            if (scheduledMessage.type === ScheduledMessageType.SEND_MESSAGE) {
                await MessageInterface.sendMessageSync({ ...(scheduledMessage.payload as SendMessageParams) });
            }

            scheduledMessage.sentAt = new Date();
            this.notifySuccess(scheduledMessage);
        } catch (ex: any) {
            this.log.info(`Failed to send scheduled message: ${ex?.message ?? String(ex)}`);
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
