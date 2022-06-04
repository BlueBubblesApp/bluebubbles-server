import { MigrationInterface, QueryRunner } from "typeorm";

export class ContactTables1654364212766 implements MigrationInterface {

    name = 'ContactTables1654364212766'

    async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.query(`
            CREATE TABLE IF NOT EXISTS "contact" (
                "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
                "first_name" text NOT NULL,
                "last_name" text NOT NULL,
                "avatar" text,
                "created" datetime NOT NULL DEFAULT (datetime('now')),
                "updated" datetime NOT NULL DEFAULT (datetime('now')),
                "display_name" text,
                CONSTRAINT "UQ_329d7cf43bb68fb3c888df2f02f" UNIQUE ("first_name", "last_name")
            )
        `);

        await queryRunner.query(`
            CREATE TABLE IF NOT EXISTS "contact_address" (
                "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
                "address" text NOT NULL,
                "type" text NOT NULL,
                "created" datetime NOT NULL DEFAULT (datetime('now')),
                "updated" datetime NOT NULL DEFAULT (datetime('now')),
                "contactId" integer,
                CONSTRAINT "UQ_51ec2c5c1ef62228395b22e929f" UNIQUE ("address", "contactId"),
                CONSTRAINT "FK_b50e57827abe529a5bd39bfcc64" FOREIGN KEY ("contactId")
                REFERENCES "contact" ("id") ON DELETE CASCADE ON UPDATE NO ACTION
            )
        `);
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
};
