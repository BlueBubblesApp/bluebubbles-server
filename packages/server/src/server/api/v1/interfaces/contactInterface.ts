import { Server } from "@server";
import { Record } from "@server/databases/contacts/entity/Record";
import { PhoneNumber } from "@server/databases/contacts/entity/PhoneNumber";
import { Email } from "@server/databases/contacts/entity/Email";

export class ContactInterface {
    private static mapContacts(records: Record[]): any {
        return records
            .filter((e: Record) => e.firstName || e.lastName)
            .map((e: Record) => {
                return {
                    phoneNumbers: e.phoneNumbers.map((p: PhoneNumber) => {
                        return {
                            isPrimary: p.isPrimary,
                            address: p.address,
                            areaCode: p.areaCode,
                            lastFourDigits: p.lastFourDigits,
                            countryCode: p.countryCode,
                            label: p.label,
                            extension: p.extension
                        };
                    }),
                    emails: e.emails.map((p: Email) => {
                        return {
                            isPrimary: p.isPrimary,
                            address: p.address,
                            label: p.label
                        };
                    }),
                    firstName: e.firstName,
                    lastName: e.lastName
                };
            });
    }

    static async getAllContacts(): Promise<any[]> {
        const data: Record[] = await Server().contactsRepo.getAllContacts();
        return ContactInterface.mapContacts(data);
    }

    static async queryContacts(addresses: string[]): Promise<any[]> {
        const data: Record[] = [];

        for (const i of addresses) {
            const res: Record = await Server().contactsRepo.getContactByAddress(i);
            if (!res) continue;
            data.push(res);
        }

        return ContactInterface.mapContacts(data);
    }
}
