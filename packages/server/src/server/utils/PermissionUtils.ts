import { execSync } from "child_process";
import { Server } from "@server";
import { ContactsLib } from "@server/api/lib/ContactsLib";


/**
 * Returns the bundle identifier for the current app.
 * In production (packaged), this is "com.BlueBubbles.BlueBubbles-Server".
 * In development (Electron), this is "com.github.Electron".
 */
export const getAppBundleId = (): string => {
    return process.env.NODE_ENV === "production"
        ? "com.BlueBubbles.BlueBubbles-Server"
        : "com.github.Electron";
};

/**
 * Attempts to grant Contacts permission via the system TCC database.
 * Uses osascript to run a privileged sqlite3 command, which shows
 * a native macOS password dialog to the user.
 * Returns true if successful, false otherwise.
 */
export const grantContactsViaTCC = async (): Promise<boolean> => {
    const bundleId = getAppBundleId();
    const sql = `INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, indirect_object_identifier, boot_uuid) VALUES ('kTCCServiceAddressBook', '${bundleId}', 0, 2, 0, 1, 0, 'UNUSED', 'UNUSED');`;
    const cmd = `do shell script "sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \\"${sql}\\"" with administrator privileges`;

    try {
        execSync(`osascript -e '${cmd}'`, { timeout: 30000 });
        return true;
    } catch (ex) {
        Server().log(`Failed to grant contacts via TCC: ${ex}`, "debug");
        return false;
    }
};

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