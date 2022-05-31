import { Server } from "@server";

const contacts = require("node-mac-contacts");


export const getContactPermissionStatus = async (): Promise<string> => {
    // Check for contact permissions
    let contactStatus = "Unknown";
    try {
        // If denied, this will not re-request the permission
        contactStatus = await contacts.requestAccess();
    } catch (ex) {
        Server().log(`Failed to request contacts auth access! Error: ${ex}`, "debug");
    }

    return contactStatus;
};