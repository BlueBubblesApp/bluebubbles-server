/* eslint-disable no-bitwise */
import { Server } from "@server/index";
import { PhoneNumberUtil } from "google-libphonenumber";
import { FileSystem } from "@server/fileSystem";
import { ContactRepository } from "@server/databases/contacts";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { Chat } from "@server/databases/imessage/entity/Chat";
import { MessageRepository } from "@server/databases/imessage";

export const generateUuid = () => {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => {
        const r = (Math.random() * 16) | 0;
        const v = c === "x" ? r : (r & 0x3) | 0x8;
        return v.toString(16);
    });
};

export const concatUint8Arrays = (a: Uint8Array, b: Uint8Array): Uint8Array => {
    const newArr = new Uint8Array(a.length + b.length);
    newArr.set(a, 0);
    newArr.set(b, a.length);
    return newArr;
};

export const getiMessageNumberFormat = (address: string) => {
    const phoneUtil = PhoneNumberUtil.getInstance();
    const number = phoneUtil.parseAndKeepRawInput(address, "US");
    const formatted = phoneUtil.formatOutOfCountryCallingNumber(number, "US");
    return `+${formatted}`;
};

export const formatAddressList = (addresses: string[]) => {
    let name = null;

    if (addresses.length === 1) {
        [name] = addresses;
    } else if (addresses.length <= 4) {
        name = addresses.join(", ");
        const pos = name.lastIndexOf(", ");
        name = `${name.substring(0, pos)} & ${name.substring(pos + 2)}`;
    } else {
        name = addresses.slice(0, 3).join(", ");
        name = `${name} & ${addresses.length - 3} others`;
    }

    return name;
};

export const safeExecuteAppleScript = async (command: string) => {
    if (!command) return null;

    try {
        // Execute the command
        return (await FileSystem.executeAppleScript(command)) as string;
    } catch (ex) {
        let msg = ex.message;
        if (msg instanceof String) {
            [, msg] = msg.split("execution error: ");
            [msg] = msg.split(". (");
        }

        Server().log(msg, "warn");
        throw new Error(msg);
    }
};

export const getContactRecord = async (chat: Chat, member: Handle) => {
    // Get the corresponding
    const record = await Server().contactsRepo.getContactByAddress(member.id);

    // If the record is unknown, we want to format it
    // Otherwise, store either the full name, email, or just first name
    if (!record && !member.id.includes("@")) return { known: false, value: getiMessageNumberFormat(member.id) };
    if (!record && member.id.includes("@")) return { known: false, value: member.id };
    if (chat.participants.length === 1 || record.firstName.length === 1)
        return { known: true, value: `${record.firstName} ${record.lastName}` };

    return { known: true, value: record.firstName };
};

export const generateChatNameList = async (chatGuid: string) => {
    if (!chatGuid) throw new Error("No chat GUID provided");
    // First, lets get the members of the chat
    const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true, withSMS: true });
    if (!chats || chats.length === 0) throw new Error("Chat does not exist");

    const chat = chats[0];
    const order = await Server().iMessageRepo.getParticipantOrder(chat.ROWID);

    const names = [];
    if (!chat.displayName) {
        const knownInOrder = [];
        const unknownInOrder = [];
        const knownAsIs = [];
        const unknownAsIs = [];

        // Calculate as-is, returned from query
        for (const member of chat.participants) {
            const record = await getContactRecord(chat, member);
            if (record.known) {
                knownAsIs.push(record.value);
            } else {
                unknownAsIs.push(record.value);
            }
        }

        // Calculate in order of joining
        for (const row of order) {
            // Find the corresponding participant
            const member = chat.participants.find(item => item.ROWID === row.handle_id);
            if (!member) continue;

            const record = await getContactRecord(chat, member);
            if (record.known) {
                knownInOrder.push(record.value);
            } else {
                unknownInOrder.push(record.value);
            }
        }

        // Add some name backups to the list to try if one fails
        names.push(formatAddressList([...knownInOrder, ...unknownInOrder]));
        let next = formatAddressList([...knownAsIs, ...unknownAsIs]);
        if (!names.includes(next)) names.push(next);
        next = formatAddressList([...knownAsIs.reverse(), ...unknownAsIs]);
        if (!names.includes(next)) names.push(next);
        next = formatAddressList([...knownInOrder.reverse(), ...unknownInOrder]);
        if (!names.includes(next)) names.push(next);
    } else {
        names.push(chat.displayName);
    }

    return names;
};

export const toBoolean = (input: string) => {
    if (!input || input === "0" || input === "false" || input === "no") return false;
    return true;
};

/**
 * Re
 *
 * @param input String to sanitize
 */
export const escapeDoubleQuote = (input: string) => {
    return input.replace(/"/g, '\\"'); // Replace double quote with escaped double quote
};

/**
 * Escape an Apple Script line of code (expression)
 *
 * @param input String to sanitize
 */
export const escapeOsaExp = (input: string) => {
    return input
        .replace(/\\/g, "\\\\\\\\") // Replace backslash with 4 backslashes (yes, this is on purpose)
        .replace(/"/g, '\\\\"') // Replace double quote with escaped double quote (2 backslashes)
        .replace(/\$/g, "\\$") // Replace $ with escaped $ (1 backslash)
        .replace(/`/g, "\\`") // Replace ` with escaped ` (1 backslashes)
        .replace(/\r?\n/g, "\\n"); // Replace returns with explicit new line character
};

/**
 * Removes whitespace characters
 *
 * @param input String to sanitize
 */
export const onlyAlphaNumeric = (input: string) => {
    return input.replace(/[\W_]+/g, "");
};

export const sanitizeStr = (val: string) => {
    if (!val) return val;
    const objChar = String.fromCharCode(65532);

    // Recursively replace all "obj" hidden characters
    let output = val;
    while (output.includes(objChar)) {
        output = output.replace(objChar, "");
    }

    return output.trim();
};

export const slugifyAddress = (val: string) => {
    if (!val) return val;

    // If we want to strip the dashes
    let slugRegex = /[^\d]+/g; // Strip all non-digits
    if (val.includes("@"))
        // If it's an email, change the regex
        slugRegex = /[^\w@.]+/g; // Strip non-alphanumeric except @ and .

    return val
        .toLowerCase()
        .replace(/\s+/g, "") // Replace spaces with nothing
        .replace(slugRegex, "")
        .trim();
};

export const parseMetadataString = (metadata: string): { [key: string]: string } => {
    if (!metadata) return {};

    const output: { [key: string]: string } = {};
    for (const line of metadata.split("\n")) {
        if (!line.includes("=")) continue;

        const items = line.split(" = ");
        if (items.length < 2) continue;

        const value = items[1].replace(/"/g, "").trim();
        if (value.length === 0 || value === "(") continue;

        // If all conditions to parse pass, save the key/value pair
        output[items[0].trim()] = value;
    }

    return output;
};

export const tapbackUIMap = {
    love: 1,
    like: 2,
    dislike: 3,
    laugh: 4,
    emphasize: 5,
    question: 6
};
