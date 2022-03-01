import * as base64 from "byte-base64";

const contacts = require('node-mac-contacts');

export class ContactInterface {
    private static mapContacts(records: NodeJS.Dict<any>[]): any {
        return records
            .map((e: NodeJS.Dict<any>) => {
                return {
                    // These maps are for backwards compatibility with the client.
                    // The "old" way we fetched contacts had a lot more information, but was less reliable.
                    // Technically, if we want to include more information with the phone numbers, we can add them
                    // in without breaking the client. New properties can be added, and the client can suppor them as needed
                    phoneNumbers: (e?.phoneNumbers ?? []).map((address: string) => { return { address }; }),
                    emails: (e?.emailAddresses ?? []).map((address: string) => { return { address }; }),
                    firstName: e?.firstName,
                    lastName: e?.lastName,
                    nickname: e?.nickname,
                    birthday: e?.birthday,
                    avatar: e?.contactImage && e?.contactImage.length > 0 ? base64.bytesToBase64(e?.contactImage) : ''
                };
            });
    }

    static findContact(address: string, { preloadedContacts }: { preloadedContacts?: any[] | null } = {}): any | null {
        const contactList = preloadedContacts ?? contacts.getAllContacts();
        const alphaNumericRegex = /[^a-zA-Z0-9_]/gi;
        const addr = address.replace(alphaNumericRegex, '');

        // Build a map where the address is the key and contact dict is the value
        const cacheMap: NodeJS.Dict<any> = {};
        for (const c of contactList) {
            const addresses = [ ...(c?.phoneNumbers ?? []), ...(c?.emailAddresses ?? [])]
                .map((e) => e.replace(alphaNumericRegex, ''));
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
            const matches = Object.keys(cacheMap).filter((e) => e && e.endsWith(ending));
            if (matches && matches.length > 0) {
                output = cacheMap[matches[0]];
                break;
            }
        }

        return output;
    }

    static getAllContacts(extraProperties: string[] = []): any[] {
        return ContactInterface.mapContacts(contacts.getAllContacts(extraProperties));
    }

    static async queryContacts(addresses: string[], extraProperties: string[] = []): Promise<any[]> {
        const data: any[] = [];
        
        const contactList = contacts.getAllContacts(extraProperties);
        for (const i of addresses) {
            const found = ContactInterface.findContact(i, { preloadedContacts: contactList });
            if (found) {
                data.push(found);
            }
        }

        return ContactInterface.mapContacts(data);
    }
}
