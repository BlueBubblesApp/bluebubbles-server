import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class ContactTables1654432080899 implements MigrationInterface {

    name = 'ContactTables1654432080899'

    contactColumnOrder = 'id, first_name, last_name, display_name, avatar, created, updated';

    contactAddressColumnOrder = 'id, address, type, created, updated';

    createContactTable = `
        CREATE TABLE IF NOT EXISTS "contact" (
            "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
            "first_name" text NOT NULL DEFAULT '',
            "last_name" text NOT NULL DEFAULT '',
            "display_name" text NOT NULL DEFAULT '',
            "avatar" text,
            "created" datetime NOT NULL DEFAULT (datetime('now')),
            "updated" datetime NOT NULL DEFAULT (datetime('now')),
            CONSTRAINT "UQ_329d7cf43bb68fb3c888df2f02f" UNIQUE ("first_name", "last_name", "display_name")
        );
    `;

    createContactAddressTable = `
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
        );
    `;

    async up(queryRunner: QueryRunner): Promise<void> {
        Server().log(`Migration[${this.name}] Ensure Contact tables exists...`, 'debug');
        await queryRunner.query(this.createContactTable);
        await queryRunner.query(this.createContactAddressTable);

        // Now we need to make sure that all other versions also have a display_name unique constraint.
        // Since sqlite doesn't support updating a table's unique constraints, we have to do some magic.
        Server().log(`Migration[${this.name}] Migrating Contact table constraints...`, 'debug');
        await queryRunner.query(`PRAGMA foreign_keys=off;`);

        // 1: Rename the original table
        Server().log(`Migration[${this.name}]   -> Renaming old tables`, 'debug');
        await queryRunner.query(`ALTER TABLE "contact" RENAME TO "contact_old";`);
        await queryRunner.query(`ALTER TABLE "contact_address" RENAME TO "contact_address_old";`);

        // 2: Update the original table's entries so that any of the NOT NULL fields are never null
        Server().log(`Migration[${this.name}]   -> Ensuring no fields are NULL`, 'debug');
        await queryRunner.query(`UPDATE "contact_old" SET "first_name" = '' WHERE "first_name" IS NULL;`);
        await queryRunner.query(`UPDATE "contact_old" SET "last_name" = '' WHERE "last_name" IS NULL;`);
        await queryRunner.query(`UPDATE "contact_old" SET "display_name" = '' WHERE "display_name" IS NULL;`);
        await queryRunner.query(`UPDATE "contact_old" SET "created" = datetime('now') WHERE "created" IS NULL;`);
        await queryRunner.query(`UPDATE "contact_old" SET "updated" = datetime('now') WHERE "updated" IS NULL;`);

        // 3: Recreate the original table
        Server().log(`Migration[${this.name}]   -> Recreating Contact tables`, 'debug');
        await queryRunner.query(this.createContactTable);
        await queryRunner.query(this.createContactAddressTable);

        // 4: Insert all the data back into the original table with the updated contstraints
        Server().log(`Migration[${this.name}]   -> Transfering data to new tables`, 'debug');
        await queryRunner.query(
            `INSERT INTO "contact" (${this.contactColumnOrder}) SELECT ${this.contactColumnOrder} FROM "contact_old";`);
        await queryRunner.query(
            `INSERT INTO "contact_address" (${this.contactAddressColumnOrder}) SELECT ${
                this.contactAddressColumnOrder} FROM "contact_address_old";`);

        // 5: Drop original, renamed table
        Server().log(`Migration[${this.name}]   -> Removing original (renamed) tables`, 'debug');
        await queryRunner.query(`DROP TABLE "contact_old";`);
        await queryRunner.query(`DROP TABLE "contact_address_old";`);
        await queryRunner.query(`PRAGMA foreign_keys=on;`);

        Server().log(`Migration[${this.name}] Success!`, 'debug');
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
};
