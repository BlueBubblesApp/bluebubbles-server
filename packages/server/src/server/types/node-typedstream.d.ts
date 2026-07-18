declare module "node-typedstream" {
    export class NSAttributedString {
        string: string;
        runs: any[];

        constructor(value: string, runs: any[]);
    }

    export class Unarchiver {
        static BinaryDecoding: {
            all: number;
            decodable: number;
            none: number;
        };

        static open(data: Buffer, binaryDecoding?: number): Unarchiver;

        decodeAll(): any[];
    }
}
