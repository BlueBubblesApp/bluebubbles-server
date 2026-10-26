/**
 * Whether Messages filed this chat under Spam, derived from the chat's decoded
 * `properties` plist. `SMSCategory` 1 is the Spam list; `wasDetectedAsSMSSpam`
 * marks chats Messages flagged on its own. `chat.is_filtered` is not used: it
 * is also set on chats that sit in the main list.
 */
export function isChatFilteredAsSpam(properties: NodeJS.Dict<any>[] | null | undefined): boolean {
    if (!Array.isArray(properties)) return false;
    return properties.some(
        props =>
            props != null &&
            typeof props === "object" &&
            (isOne(props.SMSCategory) || isTrue(props.wasDetectedAsSMSSpam))
    );
}

// Plist decoders are not consistent about scalar types: a boolean may arrive
// as true, 1, or "1", and an integer as a number, a bigint (for 8-byte ints)
// or a numeric string. Accept the obvious encodings of each.
function isOne(value: unknown): boolean {
    if (typeof value === "bigint") return value === BigInt(1);
    if (typeof value === "string") return value.trim() === "1";
    return value === 1;
}

function isTrue(value: unknown): boolean {
    if (value === true) return true;
    return isOne(value) || (typeof value === "string" && value.trim().toLowerCase() === "true");
}
