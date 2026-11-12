/** Firebase rejects a data message whose keys and values exceed 4096 bytes. */
export const FCM_MAX_DATA_BYTES = 4096;

export type FcmDataPayload = { type: string; data: string };

const OPTIONAL_MESSAGE_FIELDS = ["attributedBody", "messageSummaryInfo", "payloadData", "metadata"];
const OPTIONAL_ATTACHMENT_FIELDS = ["data", "blurhash", "metadata"];

// The JSON of the whole envelope is never smaller than Firebase's key+value
// count, so anything that fits here also fits there.
const sizeOf = (payload: FcmDataPayload): number => Buffer.byteLength(JSON.stringify(payload), "utf8");

const isRecord = (value: unknown): value is Record<string, any> =>
    typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Returns a payload that fits FCM's size limit, or null when it cannot be made to.
 *
 * A long message, or one in a large group whose participant list is included,
 * goes over the limit and Firebase rejects it, so the client never gets the
 * push. Drop the participant lists and the optional rich-content fields; the
 * message text and each chat's own fields are always kept.
 */
export function fitFcmDataPayload(payload: FcmDataPayload): FcmDataPayload | null {
    if (sizeOf(payload) <= FCM_MAX_DATA_BYTES) return payload;

    let message: unknown;
    try {
        message = JSON.parse(payload.data);
    } catch {
        return null;
    }
    if (!isRecord(message)) return null;

    for (const chat of Array.isArray(message.chats) ? message.chats : []) {
        if (isRecord(chat) && Array.isArray(chat.participants)) chat.participants = [];
    }
    for (const field of OPTIONAL_MESSAGE_FIELDS) delete message[field];
    for (const attachment of Array.isArray(message.attachments) ? message.attachments : []) {
        if (!isRecord(attachment)) continue;
        for (const field of OPTIONAL_ATTACHMENT_FIELDS) delete attachment[field];
    }

    const fitted = { type: payload.type, data: JSON.stringify(message) };
    return sizeOf(fitted) <= FCM_MAX_DATA_BYTES ? fitted : null;
}
