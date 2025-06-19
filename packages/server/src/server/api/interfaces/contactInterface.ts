import { Server } from "@server";
import fs from "fs";
import vcf from "vcf";
import { Contact, ContactAddress } from "@server/databases/server/entity";
import * as base64 from "byte-base64";
import { deduplicateObjectArray, isEmpty, isNotEmpty } from "@server/helpers/utils";
import type { FindOptionsWhere } from "typeorm";
import { ContactsLib } from "../lib/ContactsLib";

type GenericContactParams = {
    contactId?: number;
    externalId?: string;
    contact?: Contact;
};

export class ContactInterface {
    private static extractEmails = (contact: any) => {
        // Normalize all the email records
        const emails = [...(contact?.emails ?? []), ...(contact?.emailAddresses ?? []), ...(contact?.addresses ?? [])]
            // Make sure all the emails are in the same format { address: xxxxxxx }
            .map(e => {
                const address = typeof e === "string" ? e : e?.address ?? e?.value ?? e?.email ?? null;
                return { address, id: e?.id ?? e?.identifier ?? null };
            })
            // Make sure that each address has a value and is actually an email
            .filter(e => {
                return isNotEmpty(e.address) && e.address.includes("@");
            });

        return deduplicateObjectArray(emails, "address");
    };

    private static extractPhoneNumbers = (contact: any) => {
        // Normalize all the email records
        const phones = [...(contact?.phones ?? []), ...(contact?.phoneNumbers ?? []), ...(contact?.addresses ?? [])]
            // Make sure all the numbers are in the same format { address: xxxxxxx }
            .map(e => {
                const address = typeof e === "string" ? e : e?.address ?? e?.value ?? e?.phone ?? e?.number ?? null;
                return { address, id: e?.id ?? e?.identifier ?? null };
            })
            // Make sure that each address has a value and is actually an email
            .filter(e => {
                return isNotEmpty(e.address) && !e.address.includes("@");
            });

        return deduplicateObjectArray(phones, "address");
    };

    /**
     * Maps a contact record (either from the DB or API), and puts it into a standard format
     *
     * @param records The list of contacts to map
     * @returns A list of contacts in a generic format
     */
    static mapContacts(
        records: any[],
        sourceType: string,
        {
            extraProps = []
        }: {
            extraProps?: string[];
        } = {}
    ): any {
        return records.map((contact: NodeJS.Dict<any>) => {
            // Load the avatar based on the selected extra fields
            let avatar = null;
            if (extraProps.includes("avatar")) {
                avatar = contact?.avatar ?? contact?.contactImage ?? contact.contactImageThumbnail;
            } else if (extraProps.includes("contactImage")) {
                avatar = contact?.contactImage ?? contact.contactImageThumbnail;
            } else if (extraProps.includes("contactImageThumbnail")) {
                avatar = contact?.contactImageThumbnail;
            }

            let displayName = contact?.displayName;
            if (isEmpty(displayName)) {
                if (isNotEmpty(contact?.firstName) && isEmpty(contact?.lastName)) displayName = contact.firstName;
                if (isNotEmpty(contact?.firstName) && isNotEmpty(contact?.lastName))
                    displayName = `${contact.firstName} ${contact.lastName}`;
                if (isEmpty(displayName) && isNotEmpty(contact?.nickname)) displayName = contact.nickname;
            }

            return {
                phoneNumbers: ContactInterface.extractPhoneNumbers(contact),
                emails: ContactInterface.extractEmails(contact),
                firstName: contact?.firstName,
                lastName: contact?.lastName,
                displayName,
                nickname: contact?.nickname,
                birthday: contact?.birthday,
                avatar: isNotEmpty(avatar) ? base64.bytesToBase64(avatar) : "",
                sourceType,
                id: contact?.identifier ?? contact?.id,
                externalId: contact?.externalId
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
        const contactList = preloadedContacts ?? ContactsLib.getAllContacts();
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
     * @param extraProps Non-default properties to fetch from the API
     * @returns A list of contact entries from the API
     */
    static getApiContacts(extraProps: string[] = []): any[] {
        // Compensate for if `avatar` is passed instead of contactImage
        if (extraProps.includes("avatar")) {
            if (!extraProps.includes("contactImage") && !extraProps.includes("contactThumbnailImage")) {
                extraProps.push("contactImage");
            }

            extraProps = extraProps.filter(e => e !== "avatar");
        }

        // Also load the thumbnail if the image is requested.
        // The regular thumbnail will take precedence over the contactImageThumbnail
        if (extraProps.includes("contactImage") && !extraProps.includes("contactThumbnailImage")) {
            extraProps.push("contactThumbnailImage");
        }

        return ContactInterface.mapContacts(ContactsLib.getAllContacts(extraProps), "api", { extraProps });
    }

    /**
     * Gets all contacts from the local server DB
     * @returns A list of contact entries from the local DB
     */
    static async getDbContacts(withAvatars = false): Promise<any[]> {
        const extraProps = withAvatars ? ["avatar"] : [];
        return ContactInterface.mapContacts(await Server().repo.getContacts(withAvatars), "db", { extraProps });
    }

    /**
     * Gets all known contacts from the API and local DBs
     *
     * @param extraProperties Non-default properties to fetch from the API
     * @returns A list of contact entries from both the API and local DB
     */
    static async getAllContacts(extraProperties: string[] = []): Promise<any[]> {
        const saniProps = extraProperties.map(e => e.toLowerCase());
        const withAvatars =
            saniProps.includes("contactimage") ||
            saniProps.includes("contactthumbnailimage") ||
            saniProps.includes("avatar");
        const apiContacts = ContactInterface.getApiContacts(extraProperties);
        const dbContacts = await ContactInterface.getDbContacts(withAvatars);
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
        const existingAddress = await Server()
            .repo.contactAddresses()
            .findOne({ where: { address, contact: { id: contact.id } }, relations: { contact: true } });
        if (!existingAddress) {
            contactAddress = await Server().repo.contactAddresses().save(contactAddress);
        } else {
            contactAddress = existingAddress;
        }

        contact.addresses.push(contactAddress);
        await Server().repo.contacts().save(contact);
        return contactAddress;
    }

    /**
     * Creates or updates a contact with addresses
     *
     * @param firstName The first name of the contact
     * @param lastname The last name of the contact
     * @param displayName The name to show for the contact
     * @param phoneNumbers A list of phone numbers to add to the contact
     * @param emails A list of emails to add to the contact
     * @returns The contact object
     */
    static async createOrUpdateContact({
        id,
        externalId,
        firstName = "",
        lastName = "",
        displayName = "",
        phoneNumbers = [],
        emails = [],
        avatar = null,
        updateEntry = false
    }: {
        id?: number;
        externalId?: string;
        firstName?: string;
        lastName?: string;
        displayName?: string;
        phoneNumbers?: string[];
        emails?: string[];
        updateEntry?: boolean;
        avatar?: Buffer | null;
    }): Promise<Contact> {
        const repo = Server().repo.contacts();
        let contact = null;

        // Throw an error if we don't have enough information to update an entry
        if (updateEntry && isEmpty(id) && isEmpty(externalId) && isEmpty(firstName) && isEmpty(lastName) && isEmpty(displayName)) {
            throw new Error(
                "To update an existing contact, you must provide one of the following: " +
                    "id, externalId, firstName, lastName, displayName"
            );
        }

        // Throw an error if we don't have enough information to create a new entry
        if (!updateEntry && isEmpty(firstName) && isEmpty(displayName)) {
            throw new Error("To create a new contact, please provide a firstName/lastName or displayName");
        }

        let existingContacts: Contact[] = [];
        if (id) {
            existingContacts = await repo.find({ where: { id }, relations: { addresses: true } });
        } else if (externalId) {
            existingContacts = await repo.find({ where: { externalId }, relations: { addresses: true } });
        } else if (firstName || lastName || displayName) {
            const where: FindOptionsWhere<Contact> = {};
            if (firstName) where.firstName = firstName;
            if (lastName) where.lastName = lastName;
            if (displayName) where.displayName = displayName;
            existingContacts = await repo.find({ where, relations: { addresses: true } });
        }

        if (updateEntry && existingContacts.length > 1) {
            throw new Error(
                "Failed to update Contact! Criteria returned multiple Contacts. " +
                    "Please add additional criteria, i.e.: firstName, lastName, displayName"
            );
        }
        if (!updateEntry && isNotEmpty(existingContacts)) {
            throw new Error("Failed to create new Contact! Existing contact with similar info already exists!");
        }

        contact = isEmpty(existingContacts) ? null : existingContacts[0];

        let isNew = false;
        if (!contact) {
            // If the contact doesn't exists, create it
            contact = repo.create({ externalId, firstName, lastName, avatar, displayName });
            await repo.save(contact);

            isNew = true;
            contact.addresses = [];
        }

        // Add the phone numbers & emails
        for (const p of phoneNumbers) {
            await this.addAddressToContact(contact, p, "phone");
        }
        for (const e of emails) {
            await this.addAddressToContact(contact, e, "email");
        }

        // If it was newly saved, we don't need to update any fields
        if (isNew) return contact;

        // For existing items, update their fields
        let updated = false;
        if (firstName !== null && firstName !== contact.firstName) {
            contact.firstName = firstName;
            updated = true;
        }

        if (lastName !== null && lastName !== contact.lastName) {
            contact.lastName = lastName;
            updated = true;
        }

        if (avatar !== null) {
            contact.avatar = avatar;
            updated = true;
        }

        if (displayName !== null && displayName !== contact.displayName) {
            contact.displayName = displayName;
            updated = true;
        }

        if (externalId !== undefined && externalId !== contact.externalId) {
            contact.externalId = externalId;
            updated = true;
        }

        if (updated) {
            await repo.save(contact);
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
        externalId,
        contact,
        throwError = true
    }: GenericContactParams & { externalId?: string; throwError?: boolean }): Promise<Contact | null> {
        if (!contactId && !contact && !externalId) {
            throw new Error("A `contactId`, `externalId`, or `contact` must be provided to find a Contact!");
        }

        let foundContact = contact;
        if (!foundContact) {
            if (contactId) {
                foundContact = await Server()
                    .repo.contacts()
                    .findOne({ where: { id: contactId }, relations: { addresses: true } });
            } else if (externalId) {
                foundContact = await Server()
                    .repo.contacts()
                    .findOne({ where: { externalId }, relations: { addresses: true } });
            }
        }
        
        if (!foundContact && throwError) {
            if (contactId) {
                throw new Error(`No contact found with the ID: ${contactId}`);
            } else if (externalId) {
                throw new Error(`No contact found with the externalId: ${externalId}`);
            } else {
                throw new Error("Contact not found");
            }
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
                .findOne({ where: { id: contactAddressId }, relations: { contact: true } }));
        if (!foundContact) {
            throw new Error(`No contact address found with the ID: ${contactAddressId}`);
        }

        return foundContact;
    }

    /**
     * Deletes a contact from the local DB
     *
     * @param contactId A number representing the contact ID
     * @param externalId A string representing the external identifier for the contact
     * @param contact The actual contact object
     */
    static async deleteContact({ contactId, externalId, contact }: GenericContactParams): Promise<void> {
        const contactToDelete = await ContactInterface.findDbContact({ contactId, externalId, contact });
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
        Server().log(`Importing VCF from path: ${filePath}`, "debug");

        const content = fs.readFileSync(filePath, { encoding: "utf-8" }).toString() ?? "";
        const parsed = vcf.parse(content);
        const output: Contact[] = [];
        for (const contact of parsed) {
            const nameParts = contact.get("n").valueOf().toString().split(";");
            if (nameParts.length === 0) continue;

            const params: any = {
                // If a first name isn't provided, use the middle name
                firstName: nameParts[1] ?? nameParts[2] ?? "",
                lastName: nameParts[0] ?? ""
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
                const newContact = await ContactInterface.createOrUpdateContact(params);
                output.push(newContact);
            } catch (ex: any) {
                Server().log(`Error importing contact: ${ex?.message ?? String(ex)}`);
            }
        }

        return output;
    }

    /**
     * Deletes all contacts from the "local" database
     */
    static async deleteAllContacts(): Promise<void> {
        const repo = Server().repo.contacts();
        await repo.clear();
    }
    
    /**
     * Checks if an object has the required fields to be considered a contact
     * 
     * @param data The object to check
     * @returns True if the object is a valid contact object
     */
    static isAddressObject(data: any): boolean {
        return (
            data &&
            typeof data === "object" &&
            !Array.isArray(data) &&
            (Object.keys(data).includes("firstName") || Object.keys(data).includes("displayName"))
        );
    }
    
    /**
     * Creates multiple contacts from an array of contact data
     * 
     * @param contactData Array of contact data to create
     * @returns Object containing created contacts and any errors
     */
    static async batchCreateContacts(contactData: any[]): Promise<{ contacts: Contact[], errors: any[] }> {
        const contacts: Contact[] = [];
        const errors: any[] = [];
        
        for (const item of contactData) {
            if (!ContactInterface.isAddressObject(item)) {
                errors.push({
                    entry: item,
                    error: "Input address object does not contain the required information!"
                });
                continue;
            }

            try {
                contacts.push(
                    await ContactInterface.createOrUpdateContact({
                        firstName: item.firstName ?? '',
                        lastName: item?.lastName ?? '',
                        displayName: item?.displayName ?? '',
                        phoneNumbers: item?.phoneNumbers ?? [],
                        emails: item?.emails ?? [],
                        avatar: item?.avatar ?? null,
                        updateEntry: true
                    })
                );
            } catch (ex: any) {
                console.log(ex);
                errors.push({
                    entry: item,
                    error: ex?.message ?? String(ex)
                });
            }
        }
        
        return { contacts, errors };
    }
    
    /**
     * Updates multiple contacts from an array of contact data
     * 
     * @param contactData Array of contact data to update
     * @returns Object containing updated contacts and any errors
     */
    static async batchUpdateContacts(contactData: any[]): Promise<{ contacts: Contact[], errors: any[] }> {
        const updatedContacts: Contact[] = [];
        const errors: any[] = [];
        
        for (const item of contactData) {
            try {
                // Find the contact by ID or externalId
                let contact: Contact | null = null;
                
                if (item.id) {
                    contact = await ContactInterface.findDbContact({ contactId: item.id, throwError: false });
                } else if (item.externalId) {
                    contact = await ContactInterface.findDbContact({ externalId: item.externalId, throwError: false });
                }
                
                if (!contact) {
                    errors.push({
                        entry: item,
                        error: item.id 
                            ? `Contact not found with ID: ${item.id}` 
                            : `Contact not found with externalId: ${item.externalId}`
                    });
                    continue;
                }
                
                // Update the contact with provided fields
                const updatedContact = await ContactInterface.createOrUpdateContact({
                    id: contact.id,
                    externalId: item.externalId !== undefined ? item.externalId : contact.externalId,
                    firstName: item.firstName !== undefined ? item.firstName : contact.firstName,
                    lastName: item.lastName !== undefined ? item.lastName : contact.lastName,
                    displayName: item.displayName !== undefined ? item.displayName : contact.displayName,
                    phoneNumbers: item.phoneNumbers || [],
                    emails: item.emails || [],
                    avatar: item.avatar !== undefined ? item.avatar : contact.avatar,
                    updateEntry: true
                });
                
                updatedContacts.push(updatedContact);
            } catch (ex: any) {
                console.log(ex);
                errors.push({
                    entry: item,
                    error: ex?.message ?? String(ex)
                });
            }
        }
        
        return { contacts: updatedContacts, errors };
    }
    
    /**
     * Deletes multiple contacts by ID or externalId
     * 
     * @param contactData Array of contact deletion data (containing id or externalId)
     * @returns Object containing deleted IDs and any errors
     */
    static async batchDeleteContacts(contactData: any[]): Promise<{ deletedIds: any[], errors: any[] }> {
        const deletedIds = [];
        const errors = [];
        
        for (const item of contactData) {
            try {
                if (!item.id && !item.externalId) {
                    errors.push({
                        entry: item,
                        error: "Each contact deletion must include either an 'id' or 'externalId' field!"
                    });
                    continue;
                }
                
                if (item.id) {
                    await ContactInterface.deleteContact({ contactId: item.id });
                    deletedIds.push({ id: item.id });
                } else if (item.externalId) {
                    await ContactInterface.deleteContact({ externalId: item.externalId });
                    deletedIds.push({ externalId: item.externalId });
                }
            } catch (ex: any) {
                errors.push({
                    entry: item,
                    error: ex?.message ?? String(ex)
                });
            }
        }
        
        return { deletedIds, errors };
    }
}
