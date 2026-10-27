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

// node-mac-contacts caches the result of its first getAllContacts() call natively, and keeps
// returning that same array (whatever fields it was fetched with) until the Contacts store
// reports a change. So the cache is primed once with every field we ever read, and re-primed
// after each change.
let needsPrime = true;

// Logged once per failure streak, since every contact lookup would otherwise log it again
let primeFailureLogged = false;

export class ContactsLib {
    /**
     * The optional fields the cache is primed with. Only the images are ever read
     * (see ContactInterface.mapContacts); every other optional field (notes, job title,
     * social profiles...) would be held in memory for nothing.
     */
    static cachedExtraProps = ["contactImage", "contactThumbnailImage"];

    static async requestAccess() {
        if (!contacts) return "Unknown";
        return await contacts.requestAccess();
    }

    static getAuthStatus() {
        if (!contacts) return "Unknown";
        return contacts.getAuthStatus();
    }

    /**
     * Returns every contact from the Contacts store.
     *
     * The returned array is node-mac-contacts' own cache: it is the same array on every call
     * until the store changes, so callers must never mutate it or the contacts in it.
     */
    static getAllContacts(): any[] {
        if (!contacts) return [];

        if (needsPrime) {
            try {
                const primed = contacts.getAllContacts(ContactsLib.cachedExtraProps);

                // Without access nothing is cached (an empty list is returned each time), so keep
                // priming until access is granted rather than locking in a cache with no images
                if (contacts.getAuthStatus() !== "Authorized") return primed ?? [];

                needsPrime = false;
                primeFailureLogged = false;
                ContactsLib.listenForChanges();
                return primed ?? [];
            } catch (ex: any) {
                // Nothing was cached, so the next lookup tries again
                if (!primeFailureLogged) {
                    primeFailureLogged = true;
                    Server().log(`Failed to load contacts: ${ex?.message ?? String(ex)}`, "warn");
                }

                return [];
            }
        }

        return contacts.getAllContacts(ContactsLib.cachedExtraProps) ?? [];
    }

    static listenForChanges() {
        if (!contacts) return;

        // A listener left over from before (e.g. the change event never arrived) would make setup() throw
        if (contacts.listener.isListening()) contacts.listener.remove();

        contacts.listener.setup();
        contacts.listener.once("contact-changed", (_: string) => {
            // The native cache has already been cleared; rebuild it on the next lookup
            Server().log("Detected contact change, queueing full reload...", "debug");
            needsPrime = true;
            contacts.listener.remove();
        });
    }
}
