import { MigrationInterface, QueryRunner, TableColumn, TableIndex } from "typeorm";

export class AddExternalIdToContacts1750299580000 implements MigrationInterface {
    public async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.addColumn(
            "contact",
            new TableColumn({
                name: "external_id",
                type: "text",
                isNullable: true
            })
        );
        
        await queryRunner.createIndex(
            "contact",
            new TableIndex({
                name: "IDX_CONTACT_EXTERNAL_ID",
                columnNames: ["external_id"]
            })
        );
    }

    public async down(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.dropIndex("contact", "IDX_CONTACT_EXTERNAL_ID");
        await queryRunner.dropColumn("contact", "external_id");
    }
}
