import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class ScheduledMessageTable1665083072000 implements MigrationInterface {
    name = "ScheduledMessageTable1665083072000";

    createScheduledMessageTable = `
        CREATE TABLE IF NOT EXISTS "scheduled_message" (
            "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
            "type" text NOT NULL,
            "payload" text NOT NULL,
            "scheduled_for" datetime NOT NULL,
            "schedule" text NOT NULL,
            "status" text NOT NULL DEFAULT 'pending',
            "error" text DEFAULT NULL,
            "sent_at" datetime DEFAULT NULL,
            "created" datetime NOT NULL DEFAULT (datetime('now'))
        );
    `;

    async up(queryRunner: QueryRunner): Promise<void> {
        Server().log(`Migration[${this.name}] Creating ScheduledMessage table...`, "debug");
        await queryRunner.query(this.createScheduledMessageTable);
        Server().log(`Migration[${this.name}] Success!`, "debug");
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
}
