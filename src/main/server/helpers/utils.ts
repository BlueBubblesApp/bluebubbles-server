/* eslint-disable no-bitwise */
import { PhoneNumberUtil } from "google-libphonenumber";
import { FileSystem } from "@server/fileSystem";
import { ContactRepository } from "@server/api/contacts";
import { Handle } from "@server/api/imessage/entity/Handle";
import { Chat } from "@server/api/imessage/entity/Chat";
import { MessageRepository } from "@server/api/imessage";

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

    if (addresses.length <= 4) {
        name = addresses.join(", ");
        const pos = name.lastIndexOf(", ");
        name = `${name.substring(0, pos)} & ${name.substring(pos + 2)}`;
    } else {
        name = addresses.slice(0, 3).join(", ");
        name = `${name} & ${addresses.length - 3} others`;
    }

    return name;
};

export const safeExecuteAppleScript = async (fileSystem: FileSystem, command: string) => {
    try {
        // Execute the command
        return (await fileSystem.execShellCommand(command)) as string;
    } catch (ex) {
        // Format the error a bit, and re-throw it
        const msg = ex.message.split("execution error: ")[1];
        throw new Error(msg.split(". (")[0]);
    }
};

export const getContactRecord = async (contactsRepo: ContactRepository, chat: Chat, member: Handle) => {
    // Get the corresponding
    const record = await contactsRepo.getContactByAddress(member.id);

    // If the record is unknown, we want to format it
    // Otherwise, store either the full name, email, or just first name
    if (!record && !member.id.includes("@")) return { known: false, value: getiMessageNumberFormat(member.id) };
    if (!record && member.id.includes("@")) return { known: false, value: member.id };
    if (chat.participants.length === 1 || record.firstName.length === 1)
        return { known: true, value: `${record.firstName} ${record.lastName}` };

    return { known: true, value: record.firstName };
};

export const generateChatNameList = async (
    chatGuid: string,
    iMessageRepo: MessageRepository,
    contactsRepo: ContactRepository
) => {
    if (!chatGuid.startsWith("iMessage")) throw new Error("Invalid chat GUID!");

    // First, lets get the members of the chat
    const chats = await iMessageRepo.getChats(chatGuid, true);

    if (!chats || chats.length === 0) throw new Error("Chat does not exist");

    const chat = chats[0];
    const order = await iMessageRepo.getParticipantOrder(chat.ROWID);

    const names = [];
    if (!chat.displayName) {
        const knownInOrder = [];
        const unknownInOrder = [];
        const knownAsIs = [];
        const unknownAsIs = [];

        // Calculate as-is, returned from query
        for (const member of chat.participants) {
            const record = await getContactRecord(contactsRepo, chat, member);
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

            const record = await getContactRecord(contactsRepo, chat, member);
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
