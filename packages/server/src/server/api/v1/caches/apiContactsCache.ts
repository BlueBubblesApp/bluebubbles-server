import { Server } from "@server";
import { getContactPermissionStatus } from "@server/utils/PermissionUtils";
import { ContactInterface } from "../interfaces/contactInterface";

const contacts = require("node-mac-contacts");

export class ApiContactsCache {
    contacts: any[] | null = null;

    recentlyUpdated = false;

    getApiContacts() {
        // If we aren't authorized, return an empty array without setting this.contacts.
        // This way, if a permission is changed from Denied -> Authorized, we can still
        // load the contacts because this.contacts === null
        const authorized = getContactPermissionStatus() === "Authorized";
        if (!authorized) return [];

        // If we are authorized, fetch the contacts and return them
        if (this.contacts === null) this.loadApiContacts();
        return this.contacts;
    }

    loadApiContacts(force = false) {
        // If we've already loaded the contacts, don't reload them.
        // This is due to a memory leak in v1.4.0 of node-mac-contacts
        if (!force && this.contacts !== null) return;

        this.loadContacts();
    }

    private loadContacts() {
        // Request ALL extra properties so that we can cache and deliver them all
        this.contacts = contacts.getAllContacts(ContactInterface.apiExtraProperties);
    }
}
