export const CONTACT_ERROR_CODES = {
    MISSING_UPDATE_IDENTITY: "missing-contact-identity",
    AMBIGUOUS_UPDATE_MATCH: "ambiguous-contact-match",
    DUPLICATE_CONTACT: "duplicate-contact"
} as const;

export type ContactErrorCode = (typeof CONTACT_ERROR_CODES)[keyof typeof CONTACT_ERROR_CODES];

export class ContactInterfaceError extends Error {
    readonly code: ContactErrorCode;

    constructor(code: ContactErrorCode, message: string) {
        super(message);
        this.name = "ContactInterfaceError";
        this.code = code;
    }
}
