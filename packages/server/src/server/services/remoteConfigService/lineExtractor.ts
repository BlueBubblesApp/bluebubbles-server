export class LineExtractor {

    buffer: Buffer;

    constructor () {
        this.buffer = Buffer.from([]);
    }

    *feed (data: Buffer) {
        this.buffer = Buffer.concat([this.buffer, data]);
        while (true) {
            const i = this.buffer.indexOf(10);
            if (i === -1) break;

            yield this.buffer.subarray(0, i).toString('utf-8');
            this.buffer = this.buffer.subarray(i + 1);
        }
    }
}
