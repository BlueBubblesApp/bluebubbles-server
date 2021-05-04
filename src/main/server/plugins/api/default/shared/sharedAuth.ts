import type DefaultApiPlugin from "../index";
import type { ApiDatabase } from "../database";
import { TokenHelper } from "../helpers/tokenHelper";
import { Token } from "../database/entity";

export class SharedAuth {
    public static async getToken(db: ApiDatabase, token: string): Promise<Token> {
        if (!db) throw new Error("Database has not yet been initialized!");
        return db.getToken(token);
    }

    public static async createNewToken(db: ApiDatabase, plugin: DefaultApiPlugin, name?: string): Promise<string> {
        if (!db) throw new Error("Database has not yet been initialized!");

        const token = await db.generateToken(name);
        const password = plugin.getProperty("password") as string;
        if (!password) throw new Error("Password is required, but has not been set!");
        return TokenHelper.generateJwt(token, password);
    }

    public static async refreshToken(db: ApiDatabase, plugin: DefaultApiPlugin, refreshToken: string) {
        const token = await db.getToken(refreshToken, "refreshToken");
        if (!token) throw new Error(`Invalid refresh token!`);

        // Create new token & delete the old one
        const jwt = await SharedAuth.createNewToken(db, plugin, token.name);
        await db.tokens().delete(token.id);

        // Return the new token
        return jwt;
    }
}
