/* eslint-disable no-bitwise */
import { NativeImage } from "electron";
import { encode as blurhashEncode } from "blurhash";
import { Server } from "@server";
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore: ts2305
import { PhoneNumberUtil, PhoneNumberFormat, metadata as PhoneMetadata } from "google-libphonenumber";
import { FileSystem } from "@server/fileSystem";
import { Handle } from "@server/databases/imessage/entity/Handle";
import { Chat } from "@server/databases/imessage/entity/Chat";
import { Message } from "@server/databases/imessage/entity/Message";
import { invisibleMediaChar } from "@server/api/http/constants";
import { ContactInterface } from "@server/api/interfaces/contactInterface";

export const clamp = (num: number, min: number, max: number) => Math.min(Math.max(num, min), max);

export const isTruthyBool = (value: string) => {
    return ["1", true, "true", "True"].includes(value);
};

export const getFilenameWithoutExtension = (filename: string) => {
    return filename.split(".").slice(0, -1).join(".");
};

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

export const deduplicateObjectArray = (items: any[], key: string): any[] => {
    const seen = new Set();
    return items.filter(el => {
        const duplicate = seen.has(el[key]);
        seen.add(el[key]);
        return !duplicate;
    });
};

// Parse region from phone number with country code
export const parsePhoneNumberRegion = (phoneNumber: string, defaultRegion = "US") => {
    try {
        const phoneUtil = PhoneNumberUtil.getInstance();
        const number = phoneUtil.parse(phoneNumber);
        return phoneUtil.getRegionCodeForNumber(number);
    } catch (ex) {
        return Server().region ?? defaultRegion;
    }
};

export const getiMessageAddressFormat = (address: string, preSlugged = false, pretty = false): string => {
    const phoneUtil = PhoneNumberUtil.getInstance();

    // Remove any "bad" characters
    let addr = preSlugged ? address : slugifyAddress(address);

    // If the address is an email, use it as is
    if (addr.includes("@")) return addr;

    // Check for a region code (if the address starts with a +)
    const hasRegionCode = addr.startsWith("+");

    try {
        const defaultRegion = Server().region ?? "US";
        let region = defaultRegion;
        if (!hasRegionCode) {
            // If we don't have a region code, we need to "infer" it based on the macOS locale.
            // Server().region is loaded upon app startup. If it's null (which it shouldn't be),
            // we should default to US as a region.
            const regionCode = PhoneMetadata.countryToMetadata[region][10];
            addr = `+${regionCode}${addr}`;
        } else {
            // If we have a country code, we need to use it to get the region code.
            // Which we then use to parse the number.
            region = parsePhoneNumberRegion(addr, region);
        }

        // Parse the number
        const number = phoneUtil.parseAndKeepRawInput(addr, region);

        if (pretty) {
            if (defaultRegion === region) {
                // If the region matches the server region, format it as a national number.
                return phoneUtil.format(number, PhoneNumberFormat.NATIONAL);
            } else {
                // Otherwise, format it as an international number.
                return phoneUtil.format(number, PhoneNumberFormat.INTERNATIONAL);
            }
        } else {
            // Format it without parenthesis, spaces, dashes, etc.
            // But include the region code.
            return phoneUtil.format(number, PhoneNumberFormat.E164);
        }
    } catch (ex) {
        // If anything goes wrong, return the slugged address
        return addr;
    }
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
    const record = ContactInterface.findContact(member.id);

    // If the record is unknown, we want to format it
    // Otherwise, store either the full name, email, or just first name
    if (!record && !member.id.includes("@")) {
        return { known: false, value: getiMessageAddressFormat(member.id, false, true) };
    }

    if (!record && member.id.includes("@")) return { known: false, value: member.id };
    if (chat.participants.length === 1 || record.firstName.length === 1)
        return { known: true, value: `${record.firstName} ${record.lastName}` };

    return { known: true, value: record.firstName };
};

export const generateChatNameList = async (chatGuid: string) => {
    if (!chatGuid) throw new Error("No chat GUID provided");
    // First, lets get the members of the chat
    const [chats, _] = await Server().iMessageRepo.getChats({ chatGuid, withParticipants: true });
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
    if (val.includes("@")) {
        // If it's an email, change the regex
        slugRegex = /[^\w@.-_]+/g; // Strip non-alphanumeric except @, ., _, and -
    }

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
        const [chats, _] = await Server().iMessageRepo.getChats({ chatGuid: chat.guid, withParticipants: true });
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

    // Force HTTPS if enabled, and vice versa when not enabled
    // const use_custom_cert = Server().repo.getConfig("use_custom_certificate") as boolean;
    // if (use_custom_cert && newValue.startsWith("http://")) {
    //     newValue = newValue.replace("http://", "https://");
    // } else if (!use_custom_cert && newValue.startsWith("https://")) {
    //     newValue = newValue.replace("https://", "http://");
    // }

    // Auto add scheme
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

    if (!Server().privateApi.server || !Server().privateApi?.helper) {
        throw new Error("iMessage Private API Helper is not connected!");
    }
};

export const isNotEmpty = (value: string | Array<any> | NodeJS.Dict<any> | number, trimEmpty = true): boolean => {
    if (!value) return false;

    // Handle if the input is a string
    if (typeof value === "string" && (trimEmpty ? (value as string).trim() : value).length > 0) return true;

    // Handle if the input is a list
    if (typeof value === "object" && Array.isArray(value)) {
        if (trimEmpty) return value.filter(i => isNotEmpty(i)).length > 0;
        return value.length > 0;
    }

    // Handle if the input is a dictionary
    if (typeof value === "object" && !Array.isArray(value)) return Object.keys(value).length > 0;

    // If all fails, it's not empty
    return true;
};

export const isEmpty = (value: string | Array<any> | NodeJS.Dict<any> | number, trim = true): boolean => {
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

export const resultRetryer = async ({
    maxTries = 3,
    delayMs = 1000,
    getData,
    dataLoopCondition = null
}: {
    maxTries?: number;
    delayMs?: number;
    getData: (previousData: any | null) => any;
    dataLoopCondition?: (data: any | null) => boolean;
}): Promise<any | null> => {
    // Set the default check for the loop condition to be if the data is null.
    // If it's null, keep looping.
    if (!dataLoopCondition) {
        dataLoopCondition = _ => !data;
    }

    let data = await getData(null);
    let attempt = 1;
    while (dataLoopCondition(data) && attempt < maxTries) {
        // Give it a bit to execute
        await waitMs(delayMs);

        // Re-fetch the message with the updated information
        data = await getData(data);
        attempt += 1;
    }

    return data;
};

export const resultAwaiter = async ({
    maxWaitMs = 30000,
    initialWaitMs = 250,
    waitMultiplier = 1.5,
    getData,
    extraLoopCondition = null,
    dataLoopCondition = null
}: {
    maxWaitMs?: number;
    initialWaitMs?: number;
    waitMultiplier?: number;
    getData: (previousData: any | null) => any;
    extraLoopCondition?: (data: any | null) => boolean;
    dataLoopCondition?: (data: any | null) => boolean;
}): Promise<any | null> => {
    let waitTime = initialWaitMs;
    let totalTime = 0;

    // Defaults to false because true means keep looping.
    // This condition is OR'd with the data loop condition.
    // If this was true, it would keep looping indefinitely.
    if (!extraLoopCondition) {
        extraLoopCondition = _ => false;
    }

    // Set the default check for the loop condition to be if the data is null.
    // If it's null, keep looping.
    if (!dataLoopCondition) {
        dataLoopCondition = _ => !data;
    }

    let data = await getData(null);
    while ((dataLoopCondition(data) || extraLoopCondition(data)) && totalTime < maxWaitMs) {
        // Give it a bit to execute
        await waitMs(waitTime);
        totalTime += waitTime;

        // Re-fetch the message with the updated information
        data = await getData(data);
        waitTime = waitTime * waitMultiplier;
    }

    return data;
};

export const getObjectAsString = (value: any): string => {
    try {
        return JSON.stringify(value);
    } catch {
        return String(value);
    }
};

export const titleCase = (str: string) => {
    return str
        .toLowerCase()
        .split(" ")
        .map(word => word.charAt(0).toUpperCase() + word.slice(1))
        .join(" ");
}