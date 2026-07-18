import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class WebhookChatGuids1710720000000 implements MigrationInterface {
    name = "WebhookChatGuids1710720000000";

    async up(queryRunner: QueryRunner): Promise<void> {
        Server().log(`Migration[${this.name}] Adding chat_guids column to webhook table...`, "debug");

        // Check if the column already exists (e.g., from a dev sync) before adding
        const table = await queryRunner.query(`PRAGMA table_info("webhook");`);
        const hasColumn = table.some((col: any) => col.name === "chat_guids");
        if (!hasColumn) {
            await queryRunner.query(`ALTER TABLE "webhook" ADD COLUMN "chat_guids" text;`);
        }

        Server().log(`Migration[${this.name}] Success!`, "debug");
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
}
