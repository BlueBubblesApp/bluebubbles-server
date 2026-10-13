import * as path from "path";
import * as fs from "fs";
import slugify from "slugify";
import { FileSystem } from "@server/fileSystem";
import { Server } from "@server";

export class BackupsInterface {
    static async saveTheme(name: string, data: any): Promise<void> {
        const saniName = `${slugify(name)}.json`;
        const themePath = path.join(FileSystem.themesDir, saniName);

        // Delete the file if it exists
        if (fs.existsSync(themePath)) {
            fs.unlinkSync(themePath);
        }

        // Write the JSON file
        fs.writeFileSync(themePath, JSON.stringify(data));
    }

    static async deleteTheme(name: string): Promise<void> {
        const saniName = `${slugify(name)}.json`;
        const themePath = path.join(FileSystem.themesDir, saniName);

        // Delete the file if it exists
        if (fs.existsSync(themePath)) {
            fs.unlinkSync(themePath);
        }
    }

    static async getThemeByName(name: string): Promise<any> {
        const saniName = `${slugify(name)}.json`;
        const themePath = path.join(FileSystem.themesDir, saniName);

        // If the file exists, read the data, otherwise return null
        if (fs.existsSync(themePath)) {
            return JSON.parse(fs.readFileSync(themePath, { encoding: "utf-8" }));
        }

        return null;
    }

    static async getAllThemes(): Promise<any> {
        const items = fs.readdirSync(FileSystem.themesDir);
        const themes = [];

        for (const i of items) {
            if (!i.endsWith(".json")) continue;
            const themePath = path.join(FileSystem.themesDir, i);

            try {
                themes.push(JSON.parse(fs.readFileSync(themePath, { encoding: "utf-8" })));
            } catch (ex) {
                Server().log(`Failed to read theme: ${themePath}`, "warn");
            }
        }

        return themes;
    }

    // Settings
    static async saveSettings(name: string, data: any): Promise<void> {
        const saniName = `${slugify(name)}.json`;
        const settingsPath = path.join(FileSystem.settingsDir, saniName);

        // Delete the file if it exists
        if (fs.existsSync(settingsPath)) {
            fs.unlinkSync(settingsPath);
        }

        // Write the JSON file
        fs.writeFileSync(settingsPath, JSON.stringify(data));
    }

    static async deleteSettings(name: string): Promise<void> {
        const saniName = `${slugify(name)}.json`;
        const settingsPath = path.join(FileSystem.settingsDir, saniName);

        // Delete the file if it exists
        if (fs.existsSync(settingsPath)) {
            fs.unlinkSync(settingsPath);
        }
    }

    static async getSettingsByName(name: string): Promise<any> {
        const saniName = `${slugify(name)}.json`;
        const settingsPath = path.join(FileSystem.settingsDir, saniName);

        // If the file exists, read the data, otherwise return null
        if (fs.existsSync(settingsPath)) {
            return JSON.parse(fs.readFileSync(settingsPath, { encoding: "utf-8" }));
        }

        return null;
    }

    static async getAllSettings(): Promise<any> {
        const items = fs.readdirSync(FileSystem.settingsDir);
        const settings = [];

        for (const i of items) {
            if (!i.endsWith(".json")) continue;
            const settingsPath = path.join(FileSystem.settingsDir, i);

            try {
                settings.push(JSON.parse(fs.readFileSync(settingsPath, { encoding: "utf-8" })));
            } catch (ex) {
                Server().log(`Failed to read settings: ${settingsPath}`, "warn");
            }
        }

        return settings;
    }
}
