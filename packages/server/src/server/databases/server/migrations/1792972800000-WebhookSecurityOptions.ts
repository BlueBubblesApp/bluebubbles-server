import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class WebhookSecurityOptions1792972800000 implements MigrationInterface {
    name = "WebhookSecurityOptions1792972800000";

    columns = ["block_private_addresses", "require_https", "follow_redirects"];

    async up(queryRunner: QueryRunner): Promise<void> {
        for (const column of this.columns) {
            // A database created via synchronize already has the column
            if (await queryRunner.hasColumn("webhook", column)) continue;

            Server().log(`Migration[${this.name}] Adding webhook.${column} column...`, "debug");
            await queryRunner.query(`ALTER TABLE "webhook" ADD COLUMN "${column}" boolean NOT NULL DEFAULT (0)`);
        }

        Server().log(`Migration[${this.name}] Success!`, "debug");
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
}
