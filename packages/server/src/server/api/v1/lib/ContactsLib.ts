import { Server } from "@server";
import { isMinHighSierra } from "@server/env";

// Only import node-mac-contacts if we are on macOS 10.13 or higher
// This is because node-mac-contacts was compiled for macOS 10.13 or higher
// This library is here to prevent a crash on lower macOS versions
let contacts: any = null;
try {
    if (isMinHighSierra) contacts = require("node-mac-contacts");
} catch {
    contacts = null;
}

// Var to track if this is the first time we are loading contacts.
// If it's the first time, we need to load all available info, so it's cached
let isFirstLoad = true;

export class ContactsLib {
    static allExtraProps = [
        'jobTitle',
        'departmentName',
        'organizationName',
        'middleName',
        'note',
        'contactImage',
        'contactThumbnailImage',
        'instantMessageAddresses',
        'socialProfiles'
    ];

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

        // If it's the first load, we need to load all available info.
        // And also listen for changes so we can reload all the info again.
        if (isFirstLoad) {
            isFirstLoad = false;
            contacts.getAllContacts(ContactsLib.allExtraProps);
            ContactsLib.listenForChanges();
        }

        return contacts.getAllContacts(extraProps);
    }

    static listenForChanges() {
        if (!contacts) return;
        contacts.listener.setup();
        contacts.listener.once('contact-changed', (_: string) => {
            Server().log("Detected contact change, queueing full reload...", "debug");
            isFirstLoad = true;
            contacts.listener.remove();
        });
    }
}