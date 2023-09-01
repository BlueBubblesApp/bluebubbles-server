import { isMinHighSierra } from "@server/helpers/utils";

// Only import node-mac-contacts if we are on macOS 10.13 or higher
// This is because node-mac-contacts was compiled for macOS 10.13 or higher
// This library is here to prevent a crash on lower macOS versions
let contacts: any = null;
try {
    if (isMinHighSierra) contacts = require("node-mac-contacts");
} catch {
    contacts = null;
}

export class ContactsLib {
    static async requestAccess() {
        if (!contacts) return "Unknown";
        return await contacts.requestAccess();
    }

    static getAuthStatus() {
        if (!contacts) return "Unknown";
        return contacts.getAuthStatus();
    }

    static getContactPermissionStatus() {
        if (!contacts) return "Unknown";
        return contacts.getContactPermissionStatus();
    }

    static getAllContacts(extraProps: string[] = []) {
        if (!contacts) return [];
        return contacts.getAllContacts(extraProps);
    }
}