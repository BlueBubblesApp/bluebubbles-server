import { QueryRunner } from "typeorm";

export const tableExists = async (queryRunner: QueryRunner, tableName: string) => {
    const res = await queryRunner.query(`SELECT name FROM sqlite_master WHERE type='table' AND name = '${tableName}'`);
    return res.length > 0;
};
