import * as Crypto from "crypto";


export class Encrypter {

    algorithm = "aes-192-cbc";

    key: Buffer =  null;

    constructor(encryptionKey: string) {
        this.key = Crypto.scryptSync(encryptionKey, "salt", 24);
    }

    encrypt(clearText: string) {
        const iv = Crypto.randomBytes(16);
        const cipher = Crypto.createCipheriv(this.algorithm, this.key, iv);
        const encrypted = cipher.update(clearText, "utf8", "hex");
        return [encrypted + cipher.final("hex"), Buffer.from(iv).toString("hex")].join("|");
    }

    dencrypt(encryptedText: string) {
        const [encrypted, iv] = encryptedText.split("|");
        if (!iv) throw new Error("IV not found");
        const decipher = Crypto.createDecipheriv(this.algorithm, this.key, Buffer.from(iv, "hex"));
        return decipher.update(encrypted, "hex", "utf8") + decipher.final("utf8");
    }
}
