import * as JWT from "jsonwebtoken";
import * as CryptoJS from "crypto-js";

import { Token } from "../database/entity";
import { DEFAULT_PASSWORD } from "../constants";

export class TokenHelper {
    public static generateJwt(token: Token, password = DEFAULT_PASSWORD) {
        const opts: JWT.SignOptions = {
            expiresIn: token.expiresIn,
            issuer: "bluebubbles-default-transport",
            notBefore: Math.floor(token.created.getTime() / 1000),
            audience: "bluebubbles-clients"
        };

        // AES encrypt the token data using the password
        const authData = JSON.stringify({ accessToken: token.accessToken, refreshToken: token.refreshToken });
        const encryptedAuth = CryptoJS.AES.encrypt(authData, password);

        // Create a JWT for the data
        return JWT.sign({ data: encryptedAuth.toString() }, password, opts);
    }
}
