import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class WebhookSigningSecret1761772200000 implements MigrationInterface {
    name = "WebhookSigningSecret1761772200000";

    async up(queryRunner: QueryRunner): Promise<void> {
        Server().log(`Migration[${this.name}] Adding signing_secret column to the webhook table...`, "debug");
        await queryRunner.query(`ALTER TABLE "webhook" ADD COLUMN "signing_secret" text DEFAULT NULL`);
        Server().log(`Migration[${this.name}] Success!`, "debug");
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
}
