import { Server } from "@server";
import { ContactsLib } from "@server/api/lib/ContactsLib";


export const getContactPermissionStatus = (): string => {
    // Check for contact permissions
    let contactStatus = "Unknown";

    try {
        contactStatus = ContactsLib.getAuthStatus();
    } catch (ex) {
        Server().log(`Failed to get contact permission status! Error: ${ex}`, "debug");
    }

    return contactStatus;
};

export const requestContactPermission = async (force = false): Promise<string> => {
    // Check for contact permissions
    let contactStatus = getContactPermissionStatus();

    try {
        // Only request access if the permission is "Not Determined" or "Unknown".
        // If the permission is denied, then it was explicitly denied and we shouldn't request it.
        if (force || contactStatus === 'Not Determined' || contactStatus === 'Unknown') {
            contactStatus = await ContactsLib.requestAccess();

            // Check the new status
            contactStatus = getContactPermissionStatus();
        }
    } catch (ex) {
        Server().log(`Failed to get contact permission status! Error: ${ex}`, "debug");
    }

    return contactStatus;
};