import { Server } from "@server";

const contacts = require("node-mac-contacts");


export const getContactPermissionStatus = (): string => {
    // Check for contact permissions
    let contactStatus = "Unknown";

    try {
        contactStatus = contacts.getAuthStatus();
    } catch (ex) {
        Server().log(`Failed to get contact permission status! Error: ${ex}`, "debug");
    }

    return contactStatus;
};

export const requestContactPermission = async (): Promise<string> => {
    // Check for contact permissions
    let contactStatus = getContactPermissionStatus();

    try {
        // Only request access if the permission is "Not Determined".
        // If the permission is denied, then it was explicitly denied and we shouldn't request it.
        if (contactStatus === 'Not Determined') {
            contactStatus = await contacts.requestAccess();

            // Check the new status
            contactStatus = getContactPermissionStatus();
        }
    } catch (ex) {
        Server().log(`Failed to get contact permission status! Error: ${ex}`, "debug");
    }

    return contactStatus;
};