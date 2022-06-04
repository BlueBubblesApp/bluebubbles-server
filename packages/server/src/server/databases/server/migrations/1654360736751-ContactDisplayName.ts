import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class ContactDisplayName1654360736751 implements MigrationInterface {

    async up(queryRunner: QueryRunner): Promise<void> {
        try {
            Server().log(`Running 'ContactDisplayName' migration...`, 'debug');
            await queryRunner.query(`UPDATE "contact" SET displayName = '' WHERE displayName IS NULL`);
            await queryRunner.query(`ALTER TABLE "contact" ALTER COLUMN displayName TEXT NOT NULL DEFAULT ''`);
            Server().log(`Migration, 'ContactDisplayName' completed!`, 'debug');
        } catch (ex: any) {
            Server().log(`Migration, 'ContactDisplayName' failed! Error: ${ex?.message ?? String(ex)}`, 'error');
        }
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Do nothing...
    }
};
