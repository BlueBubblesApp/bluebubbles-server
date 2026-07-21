import { StringDecoder } from "string_decoder";

const MAX_JSON_LINE_LENGTH = 16 * 1024 * 1024;

export class JsonLineBuffer {
    private readonly utf8Decoder = new StringDecoder("utf8");

    private incompleteLine = "";

    append(chunk: Buffer | string): string[] {
        const chunkBuffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        const decodedChunk = this.utf8Decoder.write(chunkBuffer);
        const lines = `${this.incompleteLine}${decodedChunk}`.split("\n");
        this.incompleteLine = lines.pop() ?? "";

        if (
            Buffer.byteLength(this.incompleteLine, "utf8") > MAX_JSON_LINE_LENGTH ||
            lines.some(line => Buffer.byteLength(line, "utf8") > MAX_JSON_LINE_LENGTH)
        ) {
            this.incompleteLine = "";
            throw new Error(`Private API message exceeded ${MAX_JSON_LINE_LENGTH} bytes`);
        }

        return lines.map(line => line.trim()).filter(line => line.length > 0);
    }
}
