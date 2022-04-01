import { Server } from "@server";
import fs from "fs";
import vcf from "vcf";
import { Contact, ContactAddress } from "@server/databases/server/entity";
import * as base64 from "byte-base64";

const contacts = require("node-mac-contacts");

type GenericContactParams = {
    contactId?: number;
    contact?: Contact;
};

export class ContactInterface {
    /**
     * Maps a contact record (either from the DB or API), and puts it into a standard format
     *
     * @param records The list of contacts to map
     * @returns A list of contacts in a generic format
     */
    static mapContacts(records: any[], sourceType: string): any {
        return records.map((e: NodeJS.Dict<any>) => {
            if (Object.keys(e).includes("addresses")) {
                e.phoneNumbers = [
                    ...(e?.phoneNumbers ?? []),
                    ...(e?.addresses ?? [])
                        .filter((address: any) => {
                            if (typeof address === "string") {
                                return !address.includes("@");
                            } else if (Object.keys(address).includes("address")) {
                                return !address.address.includes("@");
                            }
                        })
                        .map((address: any) => {
                            if (typeof address === "string") {
                                return { address };
                            } else {
                                return {
                                    address: address.address,
                                    id: address.id
                                };
                            }
                        })
                ];

                e.emails = [
                    ...(e?.emails ?? []),
                    ...(e?.addresses ?? [])
                        .filter((address: any) => {
                            if (typeof address === "string") {
                                return address.includes("@");
                            } else if (Object.keys(address).includes("address")) {
                                return address.address.includes("@");
                            }
                        })
                        .map((address: any) => {
                            if (typeof address === "string") {
                                return { address };
                            } else {
                                return {
                                    address: address.address,
                                    id: address.id
                                };
                            }
                        })
                ];
            }

            return {
                // These maps are for backwards compatibility with the client.
                // The "old" way we fetched contacts had a lot more information, but was less reliable.
                // Technically, if we want to include more information with the phone numbers, we can add them
                // in without breaking the client. New properties can be added, and the client can suppor them as needed
                phoneNumbers: (e?.phoneNumbers ?? []).map((address: any) => {
                    if (typeof address === "string") {
                        return { address };
                    } else {
                        return {
                            address: address.address,
                            id: address.id
                        };
                    }
                }),
                emails: (e?.emails ?? []).map((address: any) => {
                    if (typeof address === "string") {
                        return { address };
                    } else {
                        return {
                            address: address.address,
                            id: address.id
                        };
                    }
                }),
                firstName: e?.firstName,
                lastName: e?.lastName,
                nickname: e?.nickname,
                birthday: e?.birthday,
                avatar: e?.contactImage && e?.contactImage.length > 0 ? base64.bytesToBase64(e?.contactImage) : "",
                sourceType,
                id: e?.identifier ?? e?.id
            };
        });
    }

    /**
     * Finds a contact within the known contacts list by address
     *
     * @param address The address you are trying to find a contact entry for
     * @param preloadedContacts If you already loaded a list of contacts, pass it here
     * @returns A contact entry dictionary
     */
    static findContact(address: string, { preloadedContacts }: { preloadedContacts?: any[] | null } = {}): any | null {
        const contactList = preloadedContacts ?? contacts.getAllContacts();
        const alphaNumericRegex = /[^a-zA-Z0-9_]/gi;
        const addr = address.replace(alphaNumericRegex, "");

        // Build a map where the address is the key and contact dict is the value
        const cacheMap: NodeJS.Dict<any> = {};
        for (const c of contactList) {
            const addresses = [
                ...(c?.phoneNumbers ?? []).map((e: NodeJS.Dict<any>) => e.address),
                ...(c?.emailAddresses ?? []).map((e: NodeJS.Dict<any>) => e.address)
            ].map(e => e.replace(alphaNumericRegex, ""));
            for (const contactAddr of addresses) {
                cacheMap[contactAddr] = c;
            }
        }

        // Find a key that matches the last 'x' characters.
        // First, test the entire string, then slowly remove numbers from the start
        // until we find a match. If we don't find a match after testing 4 varients, we are done.
        const choices: number[] = [addr.length, addr.length - 1, addr.length - 2, addr.length - 3];
        let output: NodeJS.Dict<any> = null;
        for (const sub of choices) {
            const ending = addr.substring(addr.length - sub, addr.length);
            const matches = Object.keys(cacheMap).filter(e => e && e.endsWith(ending));
            if (matches && matches.length > 0) {
                output = cacheMap[matches[0]];
                break;
            }
        }

        return output;
    }

    /**
     * Gets all contacts from the AddressBook API
     *
     * @param extraProperties Non-default properties to fetch from the API
     * @returns A list of contact entries from the API
     */
    static getApiContacts(extraProperties: string[] = []): any[] {
        return ContactInterface.mapContacts(contacts.getAllContacts(extraProperties), "api");
    }

    /**
     * Gets all contacts from the local server DB
     * @returns A list of contact entries from the local DB
     */
    static async getDbContacts(): Promise<any[]> {
        return ContactInterface.mapContacts(
            (await Server().repo.getContacts()).map((e: any) => {
                e.phoneNumbers = e.addresses.filter((e: any) => e.type === "phone");
                e.emails = e.addresses.filter((e: any) => e.type === "email");
                return e;
            }),
            "db"
        );
    }

    /**
     * Gets all known contacts from the API and local DBs
     *
     * @param extraProperties Non-default properties to fetch from the API
     * @returns A list of contact entries from both the API and local DB
     */
    static async getAllContacts(extraProperties: string[] = []): Promise<any[]> {
        const apiContacts = ContactInterface.getApiContacts(extraProperties);
        const dbContacts = await ContactInterface.getDbContacts();
        return [...dbContacts, ...apiContacts];
    }

    /**
     * Removes a contact address from the local database
     *
     * @param addressId The ID for the address to remove
     */
    static async deleteContactAddress({
        contactAddressId,
        contactAddress
    }: {
        contactAddressId?: number;
        contactAddress?: ContactAddress;
    }): Promise<void> {
        const contactToDelete = await ContactInterface.findDbContactAddress({ contactAddressId, contactAddress });
        await Server().repo.contactAddresses().delete(contactToDelete.id);
    }

    /**
     * Adds an address to a contact in the local DB
     *
     * @param contactId The ID for the contact to add the address to
     * @param address The address to add to the contact
     * @param addressType The type of address to create
     * @returns A contact object
     */
    static async addAddressToContactById(
        contactId: number,
        address: string,
        addressType: "phone" | "email"
    ): Promise<ContactAddress> {
        const contact = await ContactInterface.findDbContact({ contactId });
        return await ContactInterface.addAddressToContact(contact, address, addressType);
    }

    /**
     * Adds an address to a contact in the local DB
     *
     * @param contact The contact object to add the address to
     * @param address The address to add to the contact
     * @param addressType The type of address to create
     * @returns A contact object
     */
    static async addAddressToContact(
        contact: Contact,
        address: string,
        addressType: "phone" | "email"
    ): Promise<ContactAddress> {
        // Create & add the address
        let contactAddress = Server().repo.contactAddresses().create({ address, type: addressType });
        console.log("existing params");
        console.log({ address, id: contact.id });
        const existingAddress = await Server()
            .repo.contactAddresses()
            .findOne({ address, contact: { id: contact.id } }, { relations: ["contact"] });
        console.log("existing");
        console.log(existingAddress);
        if (!existingAddress) {
            contactAddress = await Server().repo.contactAddresses().save(contactAddress);
        } else {
            contactAddress = existingAddress;
        }

        console.log("saved contact address");
        console.log(contactAddress);

        contact.addresses.push(contactAddress);
        await Server().repo.contacts().save(contact);

        console.log("saved contact");
        console.log(contact);
        return contactAddress;
    }

    /**
     * Creates or updates a contact with addresses
     *
     * @param firstName The first name of the contact
     * @param lastname The last name of the contact
     * @param phoneNumbers A list of phone numbers to add to the contact
     * @param emails A list of emails to add to the contact
     * @returns The contact object
     */
    static async createContact({
        firstName,
        lastName,
        phoneNumbers = [],
        emails = [],
        updateEntry = false
    }: {
        firstName: string;
        lastName: string;
        phoneNumbers?: string[];
        emails?: string[];
        updateEntry?: boolean;
    }): Promise<Contact> {
        const repo = Server().repo.contacts();
        let contact = await repo.findOne({ firstName, lastName }, { relations: ["addresses"] });
        if (contact && !updateEntry) {
            throw new Error("Contact already exists!");
        } else if (!contact) {
            // If the contact doesn't exists, create it
            contact = repo.create({ firstName, lastName });
            await repo.save(contact);
        }

        contact.addresses = [];

        // Add the phone numbers & emails
        for (const p of phoneNumbers) {
            await this.addAddressToContact(contact, p, "phone");
        }
        for (const e of emails) {
            await this.addAddressToContact(contact, e, "email");
        }

        return contact;
    }

    /**
     * Finds a contact in the database by the ID or object.
     * Throws an error if it doesn't exist.
     *
     * @param contactId A number representing the contact ID
     * @param contact The actual contact object
     * @returns A contact object
     */
    static async findDbContact({
        contactId,
        contact,
        throwError = true
    }: GenericContactParams & { throwError?: boolean }): Promise<Contact | null> {
        if (!contactId && !contact) {
            throw new Error("A `contactId` or `contact` must be provided to find a Contact!");
        }

        const foundContact =
            contact ??
            (await Server()
                .repo.contacts()
                .findOne(contactId, { relations: ["addresses"] }));
        if (!foundContact && throwError) {
            throw new Error(`No contact found with the ID: ${contactId}`);
        }

        return foundContact;
    }

    /**
     * Finds a contact address in the database by the ID or object.
     * Throws an error if it doesn't exist.
     *
     * @param contactAddressId A number representing the contact address ID
     * @param contactAddress The actual contact address object
     * @returns A contact object
     */
    static async findDbContactAddress({
        contactAddressId,
        contactAddress
    }: {
        contactAddressId?: number;
        contactAddress?: ContactAddress;
    }): Promise<ContactAddress> {
        if (!contactAddressId && !contactAddress) {
            throw new Error("A `contactAddressId` or `contactAddress` must be provided to find a Contact Address!");
        }

        const foundContact =
            contactAddress ??
            (await Server()
                .repo.contactAddresses()
                .findOne(contactAddressId, { relations: ["addresses"] }));
        if (!foundContact) {
            throw new Error(`No contact address found with the ID: ${contactAddressId}`);
        }

        return foundContact;
    }

    /**
     * Deletes a contact from the local DB
     *
     * @param contactId A number representing the contact ID
     * @param contact The actual contact object
     */
    static async deleteContact({ contactId, contact }: GenericContactParams): Promise<void> {
        const contactToDelete = await ContactInterface.findDbContact({ contactId, contact });
        await Server().repo.contacts().delete(contactToDelete.id);
    }

    /**
     * Query all your contacts for one or more address matches
     *
     * @param addresses A list of addresses to match on
     * @param extraProperties A list of non-default properties to fetch from the API contacts
     * @returns A list of contacts matching the addresses
     */
    static async queryContacts(addresses: string[], extraProperties: string[] = []): Promise<any[]> {
        const data: any[] = [];

        const contactList = await ContactInterface.getAllContacts(extraProperties);
        for (const i of addresses) {
            const found = ContactInterface.findContact(i, { preloadedContacts: contactList });
            if (found) {
                data.push(found);
            }
        }

        return data;
    }

    /**
     * Imports contacts from a VCF
     *
     * @param filePath File Path to VCF
     * @returns A list of new contacts added
     */
    static async importFromVcf(filePath: string): Promise<any[]> {
        const content = fs.readFileSync(filePath, { encoding: "utf-8" }).toString() ?? "";
        const parsed = vcf.parse(content);
        const output: Contact[] = [];
        for (const contact of parsed) {
            const nameParts = contact
                .get("n")
                .valueOf()
                .toString()
                .split(";")
                .reverse()
                .filter(e => e && e.length > 0);
            if (nameParts.length === 0) continue;

            const params: any = {
                firstName: nameParts[0],
                lastName: nameParts.length > 1 ? nameParts.slice(1).join(" ") : ""
            };

            if (contact.get("tel")) {
                const phonesUnparsed = contact.get("tel").valueOf().toString();
                if (phonesUnparsed.includes(",") && phonesUnparsed.includes(":")) {
                    const parsedPhones = phonesUnparsed
                        .split(",")
                        .filter(e => e.includes(":"))
                        .map(e => e.split(":")[1]);
                    params.phoneNumbers = parsedPhones;
                } else {
                    params.phoneNumbers = [phonesUnparsed];
                }
            }
            if (contact.get("email")) {
                const emailsUnparsed = contact.get("email").valueOf().toString();
                if (emailsUnparsed.includes(",") && emailsUnparsed.includes(":")) {
                    const parsedEmails = emailsUnparsed
                        .split(",")
                        .filter(e => e.includes(":"))
                        .map(e => e.split(":")[1]);
                    params.emails = parsedEmails;
                } else {
                    params.emails = [emailsUnparsed];
                }
            }

            try {
                const newContact = await ContactInterface.createContact(params);
                output.push(newContact);
            } catch (ex: any) {
                Server().log(`Error importing contact: ${ex?.message ?? String(ex)}`);
            }
        }

        return output;
    }
}
