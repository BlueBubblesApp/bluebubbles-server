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
 * A class that facilitates sending events over the swift helper socket.
 */
export class Event {
    /**
     * The name of the socket event
     */
    event: string;

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
     * @param {string} event The name of the socket event
     * @param {Buffer} data The message payload
     * @param {string} [uuid] An optional uuid to use for this message. If not provided, a new uuid will be generated.
     */
    constructor(event: string, data: Buffer, uuid?: string) {
        this.event = event;
        this.data = data;
        this.uuid = uuid ?? generateUuid();
    }

    /**
     * Constructs a SocketMessage from a Buffer.
     * @param {Buffer} bytes The buffer to parse
     * @returns {Event}
     */
    static fromBytes(bytes: Buffer): Event {
        const eventStart = bytes.indexOf(START_OF_TEXT);
        const eventEnd = bytes.indexOf(END_OF_TEXT);
        const event = bytes.subarray(eventStart + 1, eventEnd).toString("ascii");
        const remain = bytes.subarray(eventEnd + 1);
        const uuidStart = remain.indexOf(START_OF_TEXT);
        const uuidEnd = remain.indexOf(END_OF_TEXT);
        const uuid = remain.subarray(uuidStart + 1, uuidEnd).toString("ascii");
        const data = remain.subarray(uuidEnd + 1);
        return new Event(event, data, uuid);
    }

    /**
     * Converts the SocketMessage to a Buffer for sending over the socket.
     * Uses the format STX+event+ETX+STX+uuid+ETX+data
     * @returns {Buffer}
     */
    toBytes(): Buffer {
        const eventBuf = Buffer.from(this.event, "ascii");
        const uuidBuf = Buffer.from(this.uuid, "ascii");
        const buf = Buffer.alloc(eventBuf.length + 2 + uuidBuf.length + 2 + this.data.length);
        let loc = 0;
        buf[loc] = START_OF_TEXT;
        eventBuf.copy(buf, (loc += 1));
        buf[(loc += eventBuf.length)] = END_OF_TEXT;
        buf[(loc += 1)] = START_OF_TEXT;
        uuidBuf.copy(buf, (loc += 1));
        buf[(loc += uuidBuf.length)] = END_OF_TEXT;
        this.data.copy(buf, (loc += 1));
        return buf;
    }
}