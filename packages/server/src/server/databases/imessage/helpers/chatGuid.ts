/**
 * The service prefixes a chat GUID can start with.
 *
 * Prior to macOS Tahoe (26), a chat GUID was prefixed with the service it was on
 * (e.g. `iMessage;-;someone@example.com` or `SMS;+;chat000000000000000001`).
 * On Tahoe, Messages migrated every chat to the literal `any` prefix
 * (e.g. `any;-;someone@example.com`), so a GUID a client cached, or constructed,
 * before the upgrade no longer matches the row in the chat.db.
 */
export const chatGuidServicePrefixes = ["any", "iMessage", "SMS", "RCS"];

const chatGuidPattern = /^([^;]+)(;[-+];.+)$/;

/**
 * Gets every variant of a chat GUID that could refer to the same chat,
 * ordered by preference. The GUID that was passed in is always first.
 *
 * Only maps between `any` and a service prefix, never from one service to another:
 * `iMessage;-;x` and `SMS;-;x` are different chats, and resolving one to the other
 * would send over a service the client did not ask for.
 *
 * Returns only the original GUID if it isn't in the `<service>;<-|+>;<identifier>` format.
 *
 * @param guid The chat GUID to get the variants for
 */
export const getChatGuidCandidates = (guid: string): string[] => {
    if (!guid) return [];

    const match = guid.match(chatGuidPattern);
    if (!match) return [guid];

    const [, prefix, remainder] = match;
    if (!chatGuidServicePrefixes.includes(prefix)) return [guid];

    if (prefix !== "any") {
        const anyGuid = `any${remainder}`;
        return anyGuid === guid ? [guid] : [guid, anyGuid];
    }

    const candidates = [guid];
    for (const servicePrefix of chatGuidServicePrefixes) {
        const candidate = `${servicePrefix}${remainder}`;
        if (!candidates.includes(candidate)) candidates.push(candidate);
    }

    return candidates;
};
