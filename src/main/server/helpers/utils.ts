/* eslint-disable no-bitwise */
import { NativeImage } from "electron";
import * as macosVersion from "macos-version";
import { encode as blurhashEncode } from "blurhash";
import { Server } from "@server/index";
import { PhoneNumberUtil } from "google-libphonenumber";
import { FileSystem } from "@server/fileSystem";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { Chat } from "@server/databases/imessage/entity/Chat";
import { Message } from "@server/databases/imessage/entity/Message";
import { invisibleMediaChar } from "@server/services/httpService/constants";

export const isMinMonteray = macosVersion.isGreaterThanOrEqualTo("12.0");
export const isMinBigSur = macosVersion.isGreaterThanOrEqualTo("11.0");
export const isMinCatalina = macosVersion.isGreaterThanOrEqualTo("10.15");
export const isMinMojave = macosVersion.isGreaterThanOrEqualTo("10.14");
export const isMinHighSierra = macosVersion.isGreaterThanOrEqualTo("10.13");
export const isMinSierra = macosVersion.isGreaterThanOrEqualTo("10.12");

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
    const number = phoneUtil.parseAndKeepRawInput(address, address.includes("+") ? null : "US");
    const formatted = phoneUtil.formatOutOfCountryCallingNumber(number, address.includes("+") ? null : "US");
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
    } catch (ex: any) {
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
    const chats = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
    if (isEmpty(chats)) throw new Error("Chat does not exist");

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

    // Recursively replace all "obj" hidden characters
    let output = val;
    while (output.includes(invisibleMediaChar)) {
        output = output.replace(invisibleMediaChar, "");
    }

    return safeTrim(output);
};

export const slugifyAddress = (val: string) => {
    if (!val) return val;

    // If we want to strip the dashes
    let slugRegex = /[^\d+]+/g; // Strip all non-digits (except +)
    if (val.includes("@"))
        // If it's an email, change the regex
        slugRegex = /[^\w@.-_]+/g; // Strip non-alphanumeric except @, ., _, and -

    return safeTrim(
        val
            .toLowerCase()
            .replace(/\s+/g, "") // Replace spaces with nothing
            .replace(slugRegex, "")
    );
};

export const parseMetadataString = (metadata: string): { [key: string]: string } => {
    if (!metadata) return {};

    const output: { [key: string]: string } = {};
    for (const line of metadata.split("\n")) {
        if (!line.includes("=")) continue;

        const items = line.split(" = ");
        if (items.length < 2) continue;

        const value = safeTrim(items[1].replace(/"/g, ""));
        if (isEmpty(value) || value === "(") continue;

        // If all conditions to parse pass, save the key/value pair
        output[safeTrim(items[0])] = value;
    }

    return output;
};

export const insertChatParticipants = async (message: Message): Promise<Message> => {
    let theMessage = message;
    if (isEmpty(theMessage.chats)) {
        theMessage = await Server().iMessageRepo.getMessage(message.guid, true, true);
    }

    for (const chat of theMessage.chats) {
        const chats = await Server().iMessageRepo.getChats({ chatGuid: chat.guid, withParticipants: true });
        if (isEmpty(chats)) continue;

        chat.participants = chats[0].participants;
    }

    return theMessage;
};

export const fixServerUrl = (value: string) => {
    let newValue = value;

    // Strip any ending slashes
    if (newValue.endsWith("/")) {
        newValue = newValue.substring(0, newValue.length - 1);
    }

    // Force HTTPS
    // if (newValue.startsWith('http://')) {
    //     newValue = newValue.replace('http://', 'https://');
    // }
    if (!newValue.startsWith("http")) {
        newValue = `http://${newValue}`;
    }

    return newValue;
};

export const getBlurHash = async ({
    image,
    width = null,
    height = null,
    quality = "good",
    componentX = 3,
    componentY = 3
}: {
    image: NativeImage;
    height?: number;
    width?: number;
    quality?: "good" | "better" | "best";
    componentX?: number;
    componentY?: number;
}): Promise<string> => {
    const resizeOpts: Electron.ResizeOptions = { quality };
    if (width) resizeOpts.width = width;
    if (height) resizeOpts.height = height;

    // Resize the image (with new quality and size if applicable)
    const calcImage: NativeImage = image.resize({ width, quality: "good" });
    const size = calcImage.getSize();

    // Compute and return blurhash
    return blurhashEncode(
        Uint8ClampedArray.from(calcImage.toBitmap()),
        size.width,
        size.height,
        componentX,
        componentY
    );
};

export const waitMs = async (ms: number) => {
    return new Promise((resolve, _) => setTimeout(resolve, ms));
};

export const checkPrivateApiStatus = () => {
    const enablePrivateApi = Server().repo.getConfig("enable_private_api") as boolean;
    if (!enablePrivateApi) {
        throw new Error("iMessage Private API is not enabled!");
    }

    if (!Server().privateApiHelper.server || !Server().privateApiHelper?.helper) {
        throw new Error("iMessage Private API Helper is not connected!");
    }
};

export const isNotEmpty = (value: string | Array<any> | NodeJS.Dict<any>, trim = true): boolean => {
    if (!value) return false;

    // Handle if the input is a string
    if (typeof value === "string" && (trim ? (value as string).trim() : value).length > 0) return true;

    // Handle if the input is a list
    if (typeof value === "object" && Array.isArray(value)) {
        if (trim) return value.filter(i => isNotEmpty(i)).length > 0;
        return value.length > 0;
    }

    // Handle if the input is a dictionary
    if (typeof value === "object" && !Array.isArray(value)) return Object.keys(value).length > 0;

    // If all fails, it's not empty
    return true;
};

export const isEmpty = (value: string | Array<any> | NodeJS.Dict<any>, trim = true): boolean => {
    return !isNotEmpty(value, trim);
};

export const shortenString = (value: string, maxLen = 25): string => {
    if (!value || typeof value !== "string") return "";
    if (value.length < maxLen) return value;
    return `${value.substring(0, maxLen)}...`;
};

// Safely trims a string
export const safeTrim = (value: string) => {
    return (value ?? "").trim();
};
