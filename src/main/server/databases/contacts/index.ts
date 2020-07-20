/* eslint-disable no-param-reassign */
import * as fs from "fs";
import { createConnection, Connection } from "typeorm";
import { PhoneNumberUtil, PhoneNumberFormat } from "google-libphonenumber";

import { Record } from "@server/databases/contacts/entity/Record";
import { PhoneNumber } from "@server/databases/contacts/entity/PhoneNumber";
import { Email } from "@server/databases/contacts/entity/Email";

/**
 * A repository class to facilitate pulling information from the iMessage database
 */
export class ContactRepository {
    db: Connection = null;

    constructor() {
        this.db = null;
    }

    /**
     * Creates a connection to the iMessage database
     */
    async initialize() {
        // We need to check which DB is the most recently updated DB
        // Either the cloud DB or the local DB
        const dbName = "AddressBook-v22.abcddb";
        const basePath = `${process.env.HOME}/Library/Application Support/AddressBook`;
        const defaultDb = `${basePath}/${dbName}`;
        let cloudDb: { path: string; lastUpdated: number } = null;

        // First, lets get the size of the default DB
        const defaultStats = fs.statSync(defaultDb);
        if (fs.existsSync(`${basePath}/Sources`)) {
            // See if there are any cloud contacts
            const dirs = fs
                .readdirSync(`${basePath}/Sources`, { withFileTypes: true })
                .filter(dirent => dirent.isDirectory());

            // Iterate over all the cloud contacts
            for (const dir of dirs) {
                // First, check if the path to the address book exists
                const tempDb = `${basePath}/Sources/${dir.name}/${dbName}`;
                if (!fs.existsSync(tempDb)) continue;

                // Get the file stats for the DB
                const cloudStats = fs.statSync(tempDb);

                // If the cloud DB has been last modified after the default DB and/or
                // modified after another cloud DB (under a different UUID), then save it
                if (
                    (!cloudDb || cloudStats.mtime.getTime() > cloudDb.lastUpdated) &&
                    cloudStats.mtime.getTime() > defaultStats.mtime.getTime()
                ) {
                    cloudDb = { path: tempDb, lastUpdated: cloudStats.mtime.getTime() };
                }
            }
        }

        this.db = await createConnection({
            name: "Contacts",
            type: "sqlite",
            database: cloudDb ? cloudDb.path : defaultDb,
            entities: [PhoneNumber, Record, Email]
        });

        return this.db;
    }

    /**
     * Get all the chats from the DB
     *
     * @param address A phone number
     */
    async getContactByAddress(address: string): Promise<Record> {
        const lastFourDigits = address.substring(address.length - 4);
        const query = this.db.getRepository(Record).createQueryBuilder("record");

        // Search by last 4 digits because we don't want to have to worry about formatting
        query.leftJoinAndSelect("record.phoneNumbers", "phoneNumber");
        query.leftJoinAndSelect("record.emails", "email");
        query.where("phoneNumber.ZLASTFOURDIGITS = :lastFourDigits", { lastFourDigits });
        query.orWhere("email.ZADDRESSNORMALIZED = :address", { address: address.toLowerCase() });

        // Fetch the results
        const records = await query.getMany();

        // Find real phone number matches
        const output = [];
        for (const record of records) {
            // Filter out numbers that don't have an exact match
            const numbers = record.phoneNumbers.filter(item => ContactRepository.sameAddress(address, item.address));
            if (record.emails.length > 0 || numbers.length > 0) output.push(record);
        }

        return output.length > 0 ? output[0] : null;
    }

    static sameAddress(first: string, second: string) {
        const phoneUtil = PhoneNumberUtil.getInstance();

        try {
            // Using national format to strip out international prefix
            let number = phoneUtil.parseAndKeepRawInput(first, "US");
            const firstFormatted = phoneUtil.format(number, PhoneNumberFormat.NATIONAL);
            number = phoneUtil.parseAndKeepRawInput(second, "US");
            const secondFormatted = phoneUtil.format(number, PhoneNumberFormat.NATIONAL);

            return firstFormatted === secondFormatted;
        } catch (ex) {
            return false;
        }
    }
}
