import * as JWT from "jsonwebtoken";
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

        return JWT.sign(
            {
                data: {
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken
                }
            },
            password,
            opts
        );
    }
}
