import { CONTACT_ERROR_CODES, ContactErrorCode } from "@server/api/interfaces/contactErrors";

const KNOWN_CONTACT_ERROR_CODES = new Set<ContactErrorCode>(Object.values(CONTACT_ERROR_CODES));

export type GoogleContactSyncCounts = {
    total: number;
    succeeded: number;
    skipped: number;
    failed: number;
};

export type GoogleContactSyncLogContext = {
    contactIndex: number;
    hasResourceName: boolean;
    hasNameRecord: boolean;
    hasGivenName: boolean;
    hasFamilyName: boolean;
    hasDisplayName: boolean;
    hasPhoneNumbers: boolean;
    hasEmailAddresses: boolean;
    hasPhotos: boolean;
};

type GoogleContactName = {
    givenName?: unknown;
    familyName?: unknown;
    displayName?: unknown;
};

type GoogleContact = {
    resourceName?: unknown;
    names?: GoogleContactName[];
    phoneNumbers?: unknown[];
    emailAddresses?: unknown[];
    photos?: unknown[];
};

const hasText = (value: unknown): boolean => typeof value === "string" && value.trim().length > 0;

const hasItems = (value: unknown): boolean => Array.isArray(value) && value.length > 0;

export const getGoogleContactSyncLogContext = (
    contact: GoogleContact,
    contactIndex: number
): GoogleContactSyncLogContext => {
    const name = hasItems(contact?.names) ? contact.names[0] : null;

    return {
        contactIndex,
        hasResourceName: hasText(contact?.resourceName),
        hasNameRecord: !!name,
        hasGivenName: hasText(name?.givenName),
        hasFamilyName: hasText(name?.familyName),
        hasDisplayName: hasText(name?.displayName),
        hasPhoneNumbers: hasItems(contact?.phoneNumbers),
        hasEmailAddresses: hasItems(contact?.emailAddresses),
        hasPhotos: hasItems(contact?.photos)
    };
};

export const formatGoogleContactSyncLogContext = (context: GoogleContactSyncLogContext): string =>
    Object.entries(context)
        .map(([key, value]) => `${key}=${value}`)
        .join(", ");

export const formatGoogleContactSyncSummary = (counts: GoogleContactSyncCounts): string =>
    `${counts.succeeded} succeeded, ${counts.skipped} skipped, ${counts.failed} failed (${counts.total} total)`;

export const getGoogleContactSyncFailureReason = (error: any): string => {
    if (KNOWN_CONTACT_ERROR_CODES.has(error?.code)) return error.code;

    return "unknown-error";
};
