/* eslint-disable no-param-reassign */
import { createConnection, Connection } from "typeorm";
import { PhoneNumberUtil, PhoneNumberFormat } from "google-libphonenumber";

import { Record } from "@server/api/contacts/entity/Record";
import { PhoneNumber } from "@server/api/contacts/entity/PhoneNumber";

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
        this.db = await createConnection({
            name: "Contacts",
            type: "sqlite",
            database: `${process.env.HOME}/Library/Application Support/AddressBook/AddressBook-v22.abcddb`,
            entities: [PhoneNumber, Record,],
            synchronize: false,
            logging: false
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
        query.innerJoinAndSelect("record.phoneNumbers", "phoneNumber");
        query.where("phoneNumber.ZLASTFOURDIGITS = :lastFourDigits", { lastFourDigits });

        // Fetch the results
        const records = await query.getMany();

        // Find real phone number matches
        const output = []
        for (const record of records) {
            // Filter out numbers that don't have an exact match
            const numbers = record.phoneNumbers.filter(item => ContactRepository.sameAddress(address, item.address));
            if (numbers.length > 0) output.push(record);
        }

        return output.length > 0 ? output[0] : null;
    }

    static sameAddress(first: string, second: string) {
        const phoneUtil = PhoneNumberUtil.getInstance();

        // Using national format to strip out international prefix
        let number = phoneUtil.parseAndKeepRawInput(first, 'US');
        const firstFormatted = phoneUtil.format(number, PhoneNumberFormat.NATIONAL);
        number = phoneUtil.parseAndKeepRawInput(second, 'US');
        const secondFormatted = phoneUtil.format(number, PhoneNumberFormat.NATIONAL);

        return (firstFormatted === secondFormatted)
    }
}
