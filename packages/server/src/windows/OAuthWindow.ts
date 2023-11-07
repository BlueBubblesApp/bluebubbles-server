import { BrowserWindow } from "electron";
import { Window } from ".";
import { Server } from "@server";

export class OAuthWindow extends Window {
    private url: string = null;

    private static self: OAuthWindow;

    private constructor(url: string) {
        super();
        this.url = url;
    }

    public static getInstance(url: string): OAuthWindow {
        if (!OAuthWindow.self) {
            OAuthWindow.self = new OAuthWindow(url);
        }

        return OAuthWindow.self;
    }

    build(): OAuthWindow {
        // Create new Browser window
        if (this.instance && !this.instance.isDestroyed) this.instance.destroy();
        this.instance = new BrowserWindow({
            width: 800,
            height: 600,
            webPreferences: {
                nodeIntegration: true
            }
        });

        this.instance.loadURL(this.url);
        this.instance.webContents.on("did-finish-load", () => {
            const url = this.instance.webContents.getURL();
            if (url.split("#")[0] !== Server().oauthService?.callbackUrl) return;

            // Extract the token from the URL
            const hash = url.split("#")[1];
            const params = new URLSearchParams(hash);
            const token = params.get("access_token");
            const expires = params.get("expires_in");
            Server().oauthService.authToken = token;
            Server().oauthService.expiresIn = Number.parseInt(expires);
            Server().oauthService.handleProjectCreation();

            // Clear the window data
            this.instance.close();
            this.instance = null;
        });

        return this;
    }
}
