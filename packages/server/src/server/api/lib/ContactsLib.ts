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

    // In-memory cache of native contact results, keyed by the requested extra-prop set.
    // node-mac-contacts' getAllContacts() is SYNCHRONOUS and, when images/thumbnails are
    // requested, marshals avatar data for every contact — multi-second on large address
    // books, which blocks the Node event loop and stalls all other HTTP requests (including
    // the socket health probe), causing clients to drop and reconnect. Caching makes repeat
    // calls instant so the synchronous native call stays off the hot path.
    private static cache: Map<string, any[]> = new Map();
    private static cacheLoadedAt = 0;
    private static readonly cacheTtlMs = 5 * 60 * 1000; // safety net; also cleared on OS contact-change

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

        // Drop the cache after the TTL as a safety net in case an OS change event is missed.
        if (ContactsLib.cacheLoadedAt && Date.now() - ContactsLib.cacheLoadedAt > ContactsLib.cacheTtlMs) {
            ContactsLib.invalidateCache();
        }

        // Serve from cache when we already have a result for this exact prop set. This keeps
        // the synchronous native call (and its event-loop block) off the hot path — repeat
        // requests, e.g. clients re-fetching contacts-with-avatars on every reconnect, are free.
        const key = JSON.stringify(extraProps.map(e => e.toLowerCase()).sort());
        const cached = ContactsLib.cache.get(key);
        if (cached) return cached;

        // If it's the first load, we need to load all available info.
        // And also listen for changes so we can reload all the info again.
        if (isFirstLoad) {
            isFirstLoad = false;
            contacts.getAllContacts(ContactsLib.allExtraProps);
            ContactsLib.listenForChanges();
        }

        const result = contacts.getAllContacts(extraProps);
        ContactsLib.cache.set(key, result);
        if (!ContactsLib.cacheLoadedAt) ContactsLib.cacheLoadedAt = Date.now();
        return result;
    }

    static invalidateCache() {
        ContactsLib.cache.clear();
        ContactsLib.cacheLoadedAt = 0;
    }

    static listenForChanges() {
        if (!contacts) return;
        contacts.listener.setup();
        contacts.listener.once('contact-changed', (_: string) => {
            Server().log("Detected contact change, queueing full reload...", "debug");
            isFirstLoad = true;
            ContactsLib.invalidateCache();
            contacts.listener.remove();
        });
    }
}