import { generateUuid } from "@server/helpers/utils";

/**
 * Represents the ASCII start of text (STX) character.
 */
const START_OF_TEXT = 0x02;
/**
 * Represents the ASCII end of text (ETX) character.
 */
const END_OF_TEXT = 0x03;
/**
 * Represents the ASCII end of transmission (EOT) character.
 */
const END_OF_TRANSMISSION = 0x04;

/**
 * A class that facilitates sending events over the swift helper socket.
 */
export class Event {
    /**
     * The name of the socket event
     */
    name: string;

    /**
     * A unique identifier for this message, used to resolve the response promise.
     */
    uuid: string;

    /**
     * The message payload
     */
    data: Buffer;

    /**
     * Constructs a new SocketMessage.
     * @param {string} name The name of the socket event
     * @param {Buffer} data The message payload
     * @param {string} [uuid] An optional uuid to use for this message. If not provided, a new uuid will be generated.
     */
    constructor(name: string, data: Buffer, uuid?: string) {
        this.name = name;
        this.data = data;
        this.uuid = uuid ?? generateUuid();
    }

    /**
     * Constructs a SocketMessage from a Buffer.
     * @param {Buffer} bytes The buffer to parse
     * @returns {Event}
     */
    static fromBytes(bytes: Buffer): Event {
        const nameStart = bytes.indexOf(START_OF_TEXT);
        const nameEnd = bytes.indexOf(END_OF_TEXT);
        const name = bytes.subarray(nameStart + 1, nameEnd).toString("ascii");
        const remain = bytes.subarray(nameEnd + 1);
        const uuidStart = remain.indexOf(START_OF_TEXT);
        const uuidEnd = remain.indexOf(END_OF_TEXT);
        const uuid = remain.subarray(uuidStart + 1, uuidEnd).toString("ascii");
        const data = remain.subarray(uuidEnd + 1);
        if (nameStart! < 0 || nameEnd! < 0 || uuidStart! < 0 || uuidEnd! < 0)
            return null;
        return new Event(name, data, uuid);
    }

    /**
     * Converts the SocketMessage to a Buffer for sending over the socket.
     * Uses the format STX+name+ETX+STX+uuid+ETX+data+EOT
     * @returns {Buffer}
     */
    toBytes(): Buffer {
        const nameBuf = Buffer.from(this.name, "ascii");
        const uuidBuf = Buffer.from(this.uuid, "ascii");
        const buf = Buffer.alloc(nameBuf.length + 2 + uuidBuf.length + 2 + this.data.length + 1);
        let loc = 0;
        buf[loc] = START_OF_TEXT;
        nameBuf.copy(buf, (loc += 1));
        buf[(loc += nameBuf.length)] = END_OF_TEXT;
        buf[(loc += 1)] = START_OF_TEXT;
        uuidBuf.copy(buf, (loc += 1));
        buf[(loc += uuidBuf.length)] = END_OF_TEXT;
        this.data.copy(buf, (loc += 1));
        buf[buf.length-1] = END_OF_TRANSMISSION;
        return buf;
    }
}