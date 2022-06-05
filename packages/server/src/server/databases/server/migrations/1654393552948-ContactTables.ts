import { Server } from "@server";
import { MigrationInterface, QueryRunner } from "typeorm";

export class ContactTables1654393552948 implements MigrationInterface {

    name = 'ContactTables1654393552948'

    createContactTable = `
        CREATE TABLE IF NOT EXISTS "contact" (
            "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
            "first_name" text NOT NULL DEFAULT '',
            "last_name" text NOT NULL DEFAULT '',
            "avatar" text,
            "created" datetime NOT NULL DEFAULT (datetime('now')),
            "updated" datetime NOT NULL DEFAULT (datetime('now')),
            "display_name" text NOT NULL DEFAULT '',
            CONSTRAINT "UQ_329d7cf43bb68fb3c888df2f02f" UNIQUE ("first_name", "last_name", "display_name")
        );
    `;

    async up(queryRunner: QueryRunner): Promise<void> {
        Server().log(`Migration[${this.name}] Ensure Contact table exists...`, 'debug');
        await queryRunner.query(this.createContactTable);

        Server().log(`Migration[${this.name}] Ensure Contact Address table exists...`, 'debug');
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
            );
        `);

        // Now we need to make sure that all other versions also have a display_name unique constraint.
        // Since sqlite doesn't support updating a table's unique constraints, we have to do some magic.
        // 1: Rename the original table
        // 2: Update the original table's entries so that display_name is never null (which it won't be later)
        // 3: Recreate the original table
        // 4: Insert all the data back into the original table with the updated contstraints
        // 5: Drop original, renamed table
        Server().log(`Migration[${this.name}] Migrating Contact table constraints...`, 'debug');
        await queryRunner.query(`PRAGMA foreign_keys=off;`);
        await queryRunner.query(`ALTER TABLE "contact" RENAME TO "contact_old";`);
        await queryRunner.query(`UPDATE "contact_old" SET "display_name" = '' WHERE "display_name" IS NULL;`);
        await queryRunner.query(this.createContactTable);
        await queryRunner.query(`INSERT INTO "contact" SELECT * FROM "contact_old";`);
        await queryRunner.query(`DROP TABLE "contact_old";`);
        await queryRunner.query(`PRAGMA foreign_keys=on;`);

        Server().log(`Migration[${this.name}] Success!`, 'debug');
    }

    async down(queryRunner: QueryRunner): Promise<void> {
        // Don't do anything
    }
};
